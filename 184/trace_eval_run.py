#!/usr/bin/env python3
"""单份 trace 只解析一次，输出 litehost 口径的 TSHG 与逐函数 self time。

口径与 trace_tshg_split.py 相同：
  T = execute_model scope 墙钟
  S = scope 内拦截 sync API 的阻塞（trace 事件并集；全部线程 / 仅主线程两版）
  H = T - S
  G = 相邻 scope 间隔
  H+G = T - S + G

用法: trace_eval_run.py LABEL trace.json[.gz]
环境: TSHG_WARMUP=0,16
输出行首标记：### 元信息 / TSHG 汇总 / FUN 逐函数
"""
import bisect
import collections
import gzip
import json
import os
import sys

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

    def sink(ts, dur, name, cat, selfd, key):
        if selfd <= 0:
            return
        fun[(cat, name)] += selfd
        func[(cat, name)] += 1
        if sync_kind(name) is None:
            return
        syncname[name] += selfd
        synccnt[name] += 1
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

    walk_self(ev, sink)
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

    print(f"### {label} FUN top60 (µs/step, calls/step)")
    for (cat, name), v in sorted(fun.items(), key=lambda kv: -kv[1])[:60]:
        print(f"FUN\t{label}\t{cat}\t{name}\t{v / nsteps:.1f}\t{func[(cat, name)] / nsteps:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
