#!/usr/bin/env python3
"""按 litehost 的 TSHG 定义切分 trace（口径见 analyze_litehost.py）：
T = scope 墙钟（litehost 用 native start_ns/end_ns）
S = scope 内 sync 调用的阻塞墙钟（litehost 用 native 拦截；此处用 trace 事件近似）
H = T - S
G = 相邻 formal scope 的 (start_next - end_next)，不允许负值
CPU 侧真实开销 = H + G

与 litehost 的已知差异（无法从 trace 恢复）：
  1. scope 锚点：litehost 包住 Worker.execute_model；trace 只能用名为
     "execute_model" 的事件，边界略窄，圈外的 host 工作会落到 G。
  2. S：litehost 由 liblitehost 拦截 sync API 得到真实阻塞时长；trace 只能按
     事件名匹配 sync 家族，未命中的 sync 会算进 H。
  3. 线程：litehost 的 state 是 static __thread，只统计 worker 主线程；
     trace 会看到进程内所有线程，默认求并集会偏大。故同时输出 S_main。

用法: trace_tshg_split.py A.json[.gz] [B.json[.gz]] [labelA] [labelB]
环境: TSHG_WARMUP=0,1,2,16   逗号分隔，一次性解析、多种 warmup 各出一份
"""
import bisect
import collections
import gzip
import json
import os
import sys

# litehost 实际拦截的同步 API（见 liblitehost.exports.txt / litehost.c）。
# 只有这些调用计入 S；cudaStreamWaitEvent / cudaEventQuery 等非阻塞调用不计。
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


def self_time(ev):
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
    out = []
    for key, evs in by_tid.items():
        evs.sort(key=lambda x: (x[0], -x[1]))
        stack = []
        for ts, end, dur, name, cat in evs:
            while stack and ts >= stack[-1][0]:
                top = stack.pop()
                out.append((top[5], top[1], top[3], top[4], top[1] - top[2], key))
                if stack:
                    stack[-1][2] += top[1]
            stack.append([end, dur, 0.0, name, cat, ts])
        while stack:
            top = stack.pop()
            out.append((top[5], top[1], top[3], top[4], top[1] - top[2], key))
            if stack:
                stack[-1][2] += top[1]
    return out


def sync_kind(name):
    n = name.lower()
    for api, kind in SYNC_APIS.items():
        if api in n:
            return kind
    return None


def is_sync(name):
    return sync_kind(name) is not None


def union_len(ivs):
    ivs = sorted(ivs)
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


def build(path, label):
    """解析一次，返回 (steps, phase, step_data, stats)。step_data 不随 warmup 变。"""
    data = load(path)
    ev = data.get("traceEvents") or data.get("events") or []

    cand = collections.defaultdict(list)
    ar = []
    for e in ev:
        if e.get("ph") != "X":
            continue
        n = e.get("name", "")
        ts = e.get("ts")
        if ts is None:
            continue
        if ": execute_model" in n and e.get("cat") != "kernel":
            cand[n].append((ts, ts + (e.get("dur") or 0), e.get("tid")))
        if "allreduce" in n and e.get("cat") == "kernel":
            ar.append(ts)

    print(f"[{label}] 步锚点候选（name: count）:")
    for n, v in sorted(cand.items(), key=lambda kv: -len(kv[1]))[:3]:
        print(f"    {len(v):6d}  {n[:100]}")

    steps = sorted(max(cand.values(), key=len)) if cand else []
    if not steps:
        print(f"[{label}] no step anchor")
        return None
    main_tids = {s[2] for s in steps}
    starts = [s[0] for s in steps]
    ar_sorted = sorted(ar)
    nsteps = len(steps)

    step_phase = {}
    step_data = {}
    for i, (s, e, _t) in enumerate(steps):
        j = bisect.bisect_left(ar_sorted, s)
        step_phase[i] = "prefill" if (j < len(ar_sorted) and ar_sorted[j] < e) else "decode"
        step_data[i] = {"T": e - s, "S": 0.0, "Sm": 0.0, "G": 0.0, "iv": [], "ivm": []}
    for i in range(nsteps - 1):
        gap = steps[i + 1][0] - steps[i][1]
        if gap < 0:
            raise ValueError(f"[{label}] overlapping scopes at step {i}: gap={gap}")
        step_data[i]["G"] = gap

    sync_by_name = collections.defaultdict(float)   # 全部线程的 self 时长
    sync_main = collections.defaultdict(float)      # 仅步锚点线程
    sync_cnt = collections.Counter()
    sync_cnt_main = collections.Counter()
    for ts, dur, name, cat, selfd, key in self_time(ev):
        if dur <= 0 or not is_sync(name):
            continue
        sync_by_name[name] += selfd
        sync_cnt[name] += 1
        is_main = key[1] in main_tids
        if is_main:
            sync_main[name] += selfd
            sync_cnt_main[name] += 1
        end = ts + dur
        i = bisect.bisect_right(starts, ts) - 1
        k = i if i >= 0 else 0
        while k < nsteps and starts[k] < end:
            s, e, _t = steps[k]
            lo = max(ts, s)
            hi = min(end, e)
            if hi > lo:
                step_data[k]["iv"].append((lo, hi))
                if is_main:
                    step_data[k]["ivm"].append((lo, hi))
            k += 1

    for p_ in step_data.values():
        p_["S"] = union_len(p_["iv"])
        p_["Sm"] = union_len(p_["ivm"])

    print(f"[{label}] steps={nsteps}  anchor_tids={sorted(main_tids)}  (共 {len(set(k[1] for k in [(e.get('pid'), e.get('tid')) for e in ev]))} 个 tid)")
    print(f"[{label}] sync 调用次数与 self 时长（全部线程 / 其中主线程）:")
    for name, v in sorted(sync_by_name.items(), key=lambda kv: -kv[1])[:10]:
        print(f"    {sync_cnt[name]:8d} 次  {v/1000:10.2f} ms   {name[:60]}")
        print(f"    {sync_cnt_main[name]:8d} 次  {sync_main[name]/1000:10.2f} ms     └ 主线程")
    if sum(sync_by_name.values()) <= 0:
        print(f"[{label}] ERROR: no sync events matched; H invalid (litehost would reject)")
        return None
    stats = {"sync_by_name": sync_by_name, "sync_cnt": sync_cnt}
    return steps, step_phase, step_data, stats


def analyze_one(built, label, warmup):
    if built is None:
        return None
    steps, step_phase, step_data, _ = built
    nsteps = len(steps)
    if warmup >= nsteps:
        print(f"[{label}] warmup={warmup} >= scopes={nsteps}")
        return None

    res = {}
    for ph in ("prefill", "decode"):
        lst = [step_data[i] for i in range(warmup, nsteps) if step_phase[i] == ph]
        if not lst:
            continue
        T_tot = sum(p["T"] for p in lst) / 1000
        S_tot = sum(p["S"] for p in lst) / 1000
        Sm_tot = sum(p["Sm"] for p in lst) / 1000
        H_tot = sum(max(0.0, p["T"] - p["S"]) for p in lst) / 1000
        Hm_tot = sum(max(0.0, p["T"] - p["Sm"]) for p in lst) / 1000
        G_tot = sum(p["G"] for p in lst) / 1000
        res[ph] = {
            "n": len(lst), "T": T_tot, "S": S_tot, "Sm": Sm_tot,
            "H": H_tot, "Hm": Hm_tot, "G": G_tot,
            "HG": H_tot + G_tot, "HGm": Hm_tot + G_tot,
            "S_ratio": S_tot / T_tot * 100 if T_tot else 0,
        }
    print(f"[{label}] warmup={warmup}  formal scopes={nsteps - warmup}  "
          f"prefill={res.get('prefill', {}).get('n', 0)} decode={res.get('decode', {}).get('n', 0)}")
    for ph in ("prefill", "decode"):
        if ph not in res:
            continue
        r = res[ph]
        print(f"  {ph:7s} n={r['n']:5d} T={r['T']:9.2f}ms S={r['S']:9.2f}ms ({r['S_ratio']:5.1f}%) "
              f"H={r['H']:8.2f}ms G={r['G']:7.2f}ms H+G={r['HG']:8.2f}ms")
        print(f"  {'':7s} 仅主线程：S={r['Sm']:9.2f}ms H={r['Hm']:8.2f}ms H+G={r['HGm']:8.2f}ms")
    return res


def cmp(ra, rb, warmup):
    print(f"\n== 跨条件对比（B - A, warmup={warmup}）==")
    for ph in ("prefill", "decode"):
        if ph not in ra or ph not in rb:
            continue
        a, b = ra[ph], rb[ph]

        def p(x, y):
            return (y - x) / x * 100 if x else float("nan")

        print(f"  {ph:7s} T {a['T']:.2f}->{b['T']:.2f}ms ({p(a['T'],b['T']):+.2f}%)  "
              f"S {a['S']:.2f}->{b['S']:.2f}ms ({p(a['S'],b['S']):+.2f}%)  "
              f"H {a['H']:.2f}->{b['H']:.2f}ms ({p(a['H'],b['H']):+.2f}%)  "
              f"G {a['G']:.2f}->{b['G']:.2f}ms ({p(a['G'],b['G']):+.2f}%)  "
              f"H+G {a['HG']:.2f}->{b['HG']:.2f}ms ({p(a['HG'],b['HG']):+.2f}%)")
        print(f"  {ph:7s} 仅主线程：S {a['Sm']:.2f}->{b['Sm']:.2f}ms ({p(a['Sm'],b['Sm']):+.2f}%)  "
              f"H {a['Hm']:.2f}->{b['Hm']:.2f}ms ({p(a['Hm'],b['Hm']):+.2f}%)  "
              f"H+G {a['HGm']:.2f}->{b['HGm']:.2f}ms ({p(a['HGm'],b['HGm']):+.2f}%)")


def main():
    warmups = [int(x) for x in os.environ.get("TSHG_WARMUP", "0").split(",") if x.strip()]
    A = sys.argv[1]
    la = sys.argv[3] if len(sys.argv) > 3 else "A"
    lb = sys.argv[4] if len(sys.argv) > 4 else "B"
    B = sys.argv[2] if len(sys.argv) > 2 else None

    print(f"=== analyze {la}: {A}")
    ba = build(A, la)
    bb = build(B, lb) if B else None
    for w in warmups:
        print(f"\n===== warmup={w}")
        ra = analyze_one(ba, la, w)
        if B:
            rb = analyze_one(bb, lb, w)
            if ra and rb:
                cmp(ra, rb, w)


if __name__ == "__main__":
    main()
