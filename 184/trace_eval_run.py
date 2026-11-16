#!/usr/bin/env python3
"""单份 trace 只解析一次，输出 litehost 口径的 TSHG 与逐函数 self time。

口径与 trace_tshg_split.py 相同：
  T = execute_model scope 墙钟
  S = scope 内拦截 sync API 的阻塞（trace 事件并集；全部线程 / 仅主线程两版）
  H = T - S
  G = 相邻 scope 间隔
  H+G = T - S + G

用法: trace_eval_run.py LABEL trace.json[.gz]
环境: TSHG_WARMUP=0,16；DEEP=1 出 scope 内逐函数；GAP=1 出 scope 间空档归因；
      HONLY=1（配合 DEEP）只统计 H 窗口（S 并集之外）的 self time；
      SWHY=1 出 S 侧 sync 阻塞的调用点归因（全线程，含 kernel 并集时长）
输出行首标记：### 元信息 / TSHG 汇总 / FUN 逐函数
"""
import bisect
import collections
import gzip
import json
import os
import re
import sys

ADDR_RE = re.compile(r" at 0x[0-9a-f]+")

# 与 litehost 实际拦截的同步 API 一致
SYNC_APIS = {
    "cudastreamsynchronize": "stream",
    "cudastreamsynchronize_ptsz": "stream",
    "custreamsynchronize": "stream",
    "custreamsynchronize_ptsz": "stream",
    "ixstreamsynchronize": "stream",
    "cudaeventsynchronize": "event",
    "cudaeventsynchronize_ptsz": "event",
    "cueventsynchronize": "event",
    "ixeventsynchronize": "event",
    "cudadevicesynchronize": "other",
    "cudathreadsynchronize": "other",
    "cuctxsynchronize": "other",
    "ixdevicesynchronize": "other",
}


def load(path):
    with open(path, "rb") as probe:
        magic = probe.read(2)
    opener = gzip.open if magic == b"\x1f\x8b" else open
    with opener(path, "rt", encoding="utf-8") as f:
        return json.load(f)


def sync_kind(name):
    n = name.lower()
    for api, kind in SYNC_APIS.items():
        if api in n:
            return kind
    return None


def union_len(ivs):
    ivs.sort()
    tot = 0.0
    cur_lo = cur_hi = None
    for lo, hi in ivs:
        if cur_lo is None:
            cur_lo, cur_hi = lo, hi
        elif lo <= cur_hi:
            cur_hi = max(cur_hi, hi)
        else:
            tot += cur_hi - cur_lo
            cur_lo, cur_hi = lo, hi
    if cur_lo is not None:
        tot += cur_hi - cur_lo
    return tot


def walk_self(ev, sink):
    """按 (pid,tid) 栈式 self time，逐个回调 sink(ts, dur, name, cat, selfd, key)。"""
    by_tid = collections.defaultdict(list)
    for e in ev:
        if e.get("ph") != "X":
            continue
        ts = e.get("ts")
        dur = e.get("dur")
        if ts is None or dur is None:
            continue
        by_tid[(e.get("pid"), e.get("tid"))].append(
            (ts, ts + dur, dur, e.get("name", ""), e.get("cat", ""))
        )
    for key, evs in by_tid.items():
        evs.sort(key=lambda x: (x[0], -x[1]))
        stack = []
        for ts, end, dur, name, cat in evs:
            while stack and ts >= stack[-1][0]:
                top = stack.pop()
                sink(top[5], top[1], top[3], top[4], top[1] - top[2], key)
                if stack:
                    stack[-1][2] += top[1]
            stack.append([end, dur, 0.0, name, cat, ts])
        while stack:
            top = stack.pop()
            sink(top[5], top[1], top[3], top[4], top[1] - top[2], key)
            if stack:
                stack[-1][2] += top[1]


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: trace_eval_run.py LABEL trace.json[.gz]")
    label, path = sys.argv[1], sys.argv[2]
    warmups = [int(x) for x in os.environ.get("TSHG_WARMUP", "0,16").split(",") if x.strip()]

    data = load(path)
    ev = data.get("traceEvents") or data.get("events") or []

    cand = collections.defaultdict(list)
    ar = []
    lo = float("inf")
    hi = float("-inf")
    tids = set()
    for e in ev:
        if e.get("ph") != "X":
            continue
        n = e.get("name", "")
        ts = e.get("ts")
        if ts is None:
            continue
        dur = e.get("dur") or 0
        lo = min(lo, ts)
        hi = max(hi, ts + dur)
        tids.add(e.get("tid"))
        if ": execute_model" in n and e.get("cat") != "kernel":
            cand[n].append((ts, ts + dur, e.get("tid")))
        if "allreduce" in n and e.get("cat") == "kernel":
            ar.append(ts)

    print(f"### {label} file={path}")
    print(f"### {label} events={len(ev)} span={(hi - lo) / 1000:.1f}ms tids={len(tids)}")
    for n, v in sorted(cand.items(), key=lambda kv: -len(kv[1]))[:3]:
        print(f"### {label} anchor {len(v):7d} {n[:110]}")
    if not cand:
        print(f"### {label} ERROR: no execute_model anchor")
        return 1

    steps = sorted(max(cand.values(), key=len))
    main_tids = {s[2] for s in steps}
    starts = [s[0] for s in steps]
    nsteps = len(steps)
    ar.sort()

    phase = {}
    for i, (s, e, _t) in enumerate(steps):
        j = bisect.bisect_left(ar, s)
        phase[i] = "prefill" if (j < len(ar) and ar[j] < e) else "decode"

    step = [{"T": e - s, "G": 0.0, "iv": [], "ivm": []} for s, e, _t in steps]
    for i in range(nsteps - 1):
        gap = steps[i + 1][0] - steps[i][1]
        if gap < 0:
            print(f"### {label} ERROR: overlapping scopes at step {i} ({gap})")
            return 1
        step[i]["G"] = gap

    fun = collections.defaultdict(float)
    func = collections.defaultdict(int)
    syncname = collections.defaultdict(float)
    synccnt = collections.Counter()

    # 深挖模式：只统计 decode 步窗口内、锚点线程上的 self time，名字去掉对象地址
    deep = os.environ.get("DEEP", "") not in ("", "0")
    gap_mode = os.environ.get("GAP", "") not in ("", "0")
    hon = os.environ.get("HONLY", "") not in ("", "0")
    swhy = os.environ.get("SWHY", "") not in ("", "0")
    dwarm = int(os.environ.get("DEEP_WARMUP", max(warmups) if warmups else 0))
    deep_topn = int(os.environ.get("DEEP_TOPN", "200"))
    gap_topn = int(os.environ.get("GAP_TOPN", "200"))

    # G 窗口：相邻两个 decode scope 之间、锚点线程的空档
    gaps = []
    if gap_mode:
        for i in range(nsteps - 1):
            if (
                i >= dwarm
                and phase[i] == "decode"
                and phase[i + 1] == "decode"
                and step[i]["G"] > 0
            ):
                gaps.append((steps[i][1], steps[i + 1][0]))
    gstarts = [g[0] for g in gaps]
    gends = [g[1] for g in gaps]
    gfun = collections.defaultdict(float)
    gfunc = collections.defaultdict(int)
    gall = collections.defaultdict(float)
    allcat = collections.defaultdict(float)
    mcat = collections.defaultdict(float)
    mfun = collections.defaultdict(float)
    mfunc = collections.defaultdict(int)
    msync = collections.defaultdict(float)
    msynccnt = collections.Counter()
    hwin = []
    swsum = [collections.defaultdict(float) for _ in range(nsteps)] if swhy else []
    swcnt = [collections.Counter() for _ in range(nsteps)] if swhy else []
    kiv = [[] for _ in range(nsteps)] if swhy else []

    def outside(ts, end, mlo, mhi):
        """[ts,end] 中不落在合并区间并集内的长度。"""
        j = bisect.bisect_right(mlo, ts) - 1
        if j < 0:
            j = 0
        ov = 0.0
        while j < len(mlo) and mlo[j] < end:
            a = max(ts, mlo[j])
            b = min(end, mhi[j])
            if b > a:
                ov += b - a
            j += 1
        return (end - ts) - ov

    def sink(ts, dur, name, cat, selfd, key):
        if selfd <= 0:
            return
        fun[(cat, name)] += selfd
        func[(cat, name)] += 1
        if deep:
            i = bisect.bisect_right(starts, ts) - 1
            if (
                0 <= i < nsteps
                and i >= dwarm
                and phase[i] == "decode"
                and ts < steps[i][1]
            ):
                allcat[cat] += selfd
                if key[1] in main_tids:
                    cn = ADDR_RE.sub("", name)
                    v = selfd
                    if hon:
                        if "execute_model" in cn or sync_kind(name) is not None:
                            v = 0.0
                        else:
                            v = outside(ts, ts + selfd, *hwin[i])
                    if v > 0:
                        mfun[(cat, cn)] += v
                        mfunc[(cat, cn)] += 1
                        mcat[cat] += v
                    if sync_kind(name) is not None:
                        msync[cn] += selfd
                        msynccnt[cn] += 1
        if gap_mode:
            j = bisect.bisect_right(gstarts, ts) - 1
            if 0 <= j < len(gaps) and ts < gends[j]:
                gall[cat] += selfd
                if key[1] in main_tids:
                    cn = ADDR_RE.sub("", name)
                    gfun[(cat, cn)] += selfd
                    gfunc[(cat, cn)] += 1
        if sync_kind(name) is None:
            return
        syncname[name] += selfd
        synccnt[name] += 1
        if hon:
            return
        end = ts + dur
        is_main = key[1] in main_tids
        k = bisect.bisect_right(starts, ts) - 1
        if k < 0:
            k = 0
        while k < nsteps and starts[k] < end:
            s, e, _t = steps[k]
            a = max(ts, s)
            b = min(end, e)
            if b > a:
                step[k]["iv"].append((a, b))
                if is_main:
                    step[k]["ivm"].append((a, b))
            k += 1

    def walk_ctx(events, sink):
        """同 walk_self，但把每个事件的最近非自身祖先 (cat, name) 一并回调。"""
        by_tid = collections.defaultdict(list)
        for e in events:
            if e.get("ph") != "X":
                continue
            ts = e.get("ts")
            dur = e.get("dur")
            if ts is None or dur is None:
                continue
            by_tid[(e.get("pid"), e.get("tid"))].append(
                (ts, ts + dur, dur, e.get("name", ""), e.get("cat", ""))
            )
        for key, evs in by_tid.items():
            evs.sort(key=lambda x: (x[0], -x[1]))
            stack = []
            for ts, end, dur, name, cat in evs:
                while stack and ts >= stack[-1][0]:
                    top = stack.pop()
                    par = (stack[-1][3], stack[-1][4]) if stack else ("", "")
                    sink(top[5], top[1], top[3], top[4], top[1] - top[2], key, par)
                    if stack:
                        stack[-1][2] += top[1]
                stack.append([end, dur, 0.0, name, cat, ts])
            while stack:
                top = stack.pop()
                par = (stack[-1][3], stack[-1][4]) if stack else ("", "")
                sink(top[5], top[1], top[3], top[4], top[1] - top[2], key, par)
                if stack:
                    stack[-1][2] += top[1]

    def sw_sink(ts, dur, name, cat, selfd, key, par):
        if sync_kind(name) is None or dur <= 0:
            return
        end = ts + dur
        role = "main" if key[1] in main_tids else "other"
        pn = ADDR_RE.sub("", par[1]) or "-"
        kk = (name, role, par[0], pn, key[1])
        k = bisect.bisect_right(starts, ts) - 1
        if k < 0:
            k = 0
        while k < nsteps and starts[k] < end:
            s, e, _t = steps[k]
            a = max(ts, s)
            b = min(end, e)
            if b > a and k >= dwarm and phase[k] == "decode":
                swsum[k][kk] += b - a
                if s <= ts < e:
                    swcnt[k][kk] += 1
            k += 1

    def ker_sink(ts, dur, name, cat, selfd, key, par):
        if cat != "kernel" or dur <= 0:
            return
        end = ts + dur
        k = bisect.bisect_right(starts, ts) - 1
        if k < 0:
            k = 0
        while k < nsteps and starts[k] < end:
            s, e, _t = steps[k]
            a = max(ts, s)
            b = min(end, e)
            if b > a and k >= dwarm and phase[k] == "decode":
                kiv[k].append((a, b))
            k += 1

    def iv_sink(ts, dur, name, cat, selfd, key):
        if sync_kind(name) is None:
            return
        end = ts + dur
        is_main = key[1] in main_tids
        k = bisect.bisect_right(starts, ts) - 1
        if k < 0:
            k = 0
        while k < nsteps and starts[k] < end:
            s, e, _t = steps[k]
            a = max(ts, s)
            b = min(end, e)
            if b > a:
                step[k]["iv"].append((a, b))
                if is_main:
                    step[k]["ivm"].append((a, b))
            k += 1

    if hon or swhy:
        walk_self(ev, iv_sink)
        for p in step:
            ivs = sorted(p["iv"])
            mlo, mhi = [], []
            for lo, hi in ivs:
                if mhi and lo <= mhi[-1]:
                    if hi > mhi[-1]:
                        mhi[-1] = hi
                else:
                    mlo.append(lo)
                    mhi.append(hi)
            hwin.append((mlo, mhi))

    walk_self(ev, sink)
    if swhy:
        walk_ctx(ev, sw_sink)
        walk_ctx(ev, ker_sink)
    data = ev = None

    for p in step:
        p["S"] = union_len(p["iv"])
        p["Sm"] = union_len(p["ivm"])
        p["iv"] = p["ivm"] = None

    print(f"### {label} sync_total={sum(synccnt.values())}")
    for name, v in sorted(syncname.items(), key=lambda kv: -kv[1])[:6]:
        print(f"###   {synccnt[name]:8d} 次 {v / 1000:10.2f} ms  {name[:60]}")

    for w in warmups:
        if w >= nsteps:
            print(f"### {label} warmup={w} >= steps={nsteps}")
            continue
        for ph in ("prefill", "decode"):
            idx = [i for i in range(w, nsteps) if phase[i] == ph]
            if not idx:
                continue
            T = sum(step[i]["T"] for i in idx) / 1000
            S = sum(step[i]["S"] for i in idx) / 1000
            Sm = sum(step[i]["Sm"] for i in idx) / 1000
            H = sum(max(0.0, step[i]["T"] - step[i]["S"]) for i in idx) / 1000
            Hm = sum(max(0.0, step[i]["T"] - step[i]["Sm"]) for i in idx) / 1000
            G = sum(step[i]["G"] for i in idx) / 1000
            print(
                f"TSHG\t{label}\tw={w}\t{ph}\tn={len(idx)}"
                f"\tT={T:.2f}\tS={S:.2f}\tSm={Sm:.2f}\tH={H:.2f}\tHm={Hm:.2f}"
                f"\tG={G:.2f}\tHG={H + G:.2f}\tHGm={Hm + G:.2f}"
                f"\tS_pct={(S / T * 100) if T else 0:.1f}"
            )

    if swhy:
        dec = [i for i in range(dwarm, nsteps) if phase[i] == "decode"]
        ndec = len(dec)
        if ndec:
            agg = collections.defaultdict(lambda: [0.0, 0])
            for i in dec:
                for kk, v in swsum[i].items():
                    agg[kk][0] += v
                    agg[kk][1] += swcnt[i][kk]
            sus = sum(step[i]["S"] for i in dec) / ndec
            smm = sum(step[i]["Sm"] for i in dec) / ndec
            tot = sum(v[0] for v in agg.values()) / ndec
            kbusy = sum(union_len(kiv[i]) for i in dec) / ndec
            print(
                f"### {label} SWHY decode_steps={ndec} S_union={sus:.1f}us/step"
                f" S_main_union={smm:.1f}us/step sync_sum={tot:.1f}us/step"
                f" kernel_union={kbusy:.1f}us/step"
            )
            print(f"### {label} SWCTX top20 (µs/step, calls/step)")
            for (api, role, pcat, pn, _tid), (v, c) in sorted(
                agg.items(), key=lambda kv: -kv[1][0]
            )[:20]:
                print(
                    f"SWCTX\t{label}\t{api}\t{role}\t{pcat}\t{pn}\t{v / ndec:.1f}\t{c / ndec:.2f}"
                )

    print(f"### {label} FUN top60 (µs/step, calls/step)")
    for (cat, name), v in sorted(fun.items(), key=lambda kv: -kv[1])[:60]:
        print(f"FUN\t{label}\t{cat}\t{name}\t{v / nsteps:.1f}\t{func[(cat, name)] / nsteps:.2f}")

    if deep:
        dec = [i for i in range(dwarm, nsteps) if phase[i] == "decode"]
        ndec = len(dec)
        if ndec:
            mt = sum(step[i]["T"] for i in dec) / ndec
            allsum = sum(allcat.values()) / ndec
            msum = sum(mcat.values()) / ndec
            mssum = sum(msync.values()) / ndec
            print(
                f"### {label} DEEP decode_steps={ndec} warmup={dwarm}"
                f" mean_T={mt:.1f}us all_self={allsum:.1f}us"
                f" main_self={msum:.1f}us main_sync={mssum:.1f}us"
            )
            for cat, v in sorted(allcat.items(), key=lambda kv: -kv[1]):
                print(f"ACAT\t{label}\t{cat}\t{v / ndec:.1f}")
            for cat, v in sorted(mcat.items(), key=lambda kv: -kv[1]):
                print(f"MCAT\t{label}\t{cat}\t{v / ndec:.1f}")
            for n, v in sorted(msync.items(), key=lambda kv: -kv[1])[:20]:
                print(f"MSYNC\t{label}\t{n}\t{v / ndec:.1f}\t{msynccnt[n] / ndec:.2f}")
            print(f"### {label} MFUN top{deep_topn} (µs/decode-step, calls/step, anchor tid)")
            for (cat, n), v in sorted(mfun.items(), key=lambda kv: -kv[1])[:deep_topn]:
                print(f"MFUN\t{label}\t{cat}\t{n}\t{v / ndec:.1f}\t{mfunc[(cat, n)] / ndec:.2f}")

    if gap_mode and gaps:
        ng = len(gaps)
        gwall = sum(e - s for s, e in gaps) / ng
        gself = sum(gfun.values()) / ng
        gallsum = sum(gall.values()) / ng
        print(
            f"### {label} GAP gaps={ng} warmup={dwarm}"
            f" mean_G={gwall:.1f}us anchor_self={gself:.1f}us all_self={gallsum:.1f}us"
        )
        for cat, v in sorted(gall.items(), key=lambda kv: -kv[1]):
            print(f"GCAT\t{label}\t{cat}\t{v / ng:.1f}")
        print(f"### {label} GFUN top{gap_topn} (µs/gap, calls/step, anchor tid)")
        for (cat, n), v in sorted(gfun.items(), key=lambda kv: -kv[1])[:gap_topn]:
            print(f"GFUN\t{label}\t{cat}\t{n}\t{v / ng:.1f}\t{gfunc[(cat, n)] / ng:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
