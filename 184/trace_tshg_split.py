#!/usr/bin/env python3
"""按 TSHG 口径切分 prefill / decode：
S = sync 类调用的 self 时长（cudaStreamSynchronize / cudaEventSynchronize / EventQuery / wait_stream ...）
H = T - S（CPU 真正干活）
G = 相邻 execute_model 步之间的间隙
CPU 侧真实开销 = H + G
"""
import bisect
import collections
import gzip
import json
import statistics
import sys

# sync 家族（小写匹配，子串）
SYNC_PATS = (
    "synchronize",        # cudaEventSynchronize / cudaStreamSynchronize / torch synchronize
    "eventquery",         # cudaEventQuery
    "wait_stream",        # torch streams wait_stream
    "wait_event",         # wait_event 类
    "streamsynchronize",
)


def load(path):
    with gzip.open(path, "rt", encoding="utf-8") as f:
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
    for evs in by_tid.values():
        evs.sort(key=lambda x: (x[0], -x[1]))
        stack = []
        for ts, end, dur, name, cat in evs:
            while stack and ts >= stack[-1][0]:
                top = stack.pop()
                out.append((top[5], top[1], top[3], top[4], top[1] - top[2]))
                if stack:
                    stack[-1][2] += top[1]
            stack.append([end, dur, 0.0, name, cat, ts])
        while stack:
            top = stack.pop()
            out.append((top[5], top[1], top[3], top[4], top[1] - top[2]))
            if stack:
                stack[-1][2] += top[1]
    return out


def is_sync(name):
    n = name.lower()
    return any(p in n for p in SYNC_PATS)


def analyze(path, label):
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
            cand[n].append((ts, ts + (e.get("dur") or 0)))
        if "allreduce" in n and e.get("cat") == "kernel":
            ar.append(ts)

    steps = sorted(max(cand.values(), key=len)) if cand else []
    if not steps:
        print(f"[{label}] no step anchor")
        return None
    starts = [s[0] for s in steps]
    ar_sorted = sorted(ar)
    nsteps = len(steps)

    step_phase = {}
    step_data = {}
    for i, (s, e) in enumerate(steps):
        j = bisect.bisect_left(ar_sorted, s)
        step_phase[i] = "prefill" if (j < len(ar_sorted) and ar_sorted[j] < e) else "decode"
        step_data[i] = {"T": e - s, "S": 0.0, "G": 0.0}
    for i in range(nsteps - 1):
        gap = steps[i + 1][0] - steps[i][1]
        if gap > 0:
            step_data[i]["G"] = gap

    sync_by_name = collections.defaultdict(float)
    for ts, dur, name, cat, selfd in self_time(ev):
        if dur <= 0 or not is_sync(name):
            continue
        end = ts + dur
        i = bisect.bisect_right(starts, ts) - 1
        k = i if i >= 0 else 0
        while k < nsteps and starts[k] < end:
            s, e = steps[k]
            lo = max(ts, s)
            hi = min(end, e)
            if hi > lo:
                part = selfd * (hi - lo) / dur
                step_data[k]["S"] += part
            k += 1
        sync_by_name[name] += selfd

    res = {}
    for ph in ("prefill", "decode"):
        lst = [step_data[i] for i in step_data if step_phase[i] == ph]
        if not lst:
            continue
        T_tot = sum(p["T"] for p in lst) / 1000
        S_tot = sum(p["S"] for p in lst) / 1000
        H_tot = sum(max(0.0, p["T"] - p["S"]) for p in lst) / 1000
        G_tot = sum(p["G"] for p in lst) / 1000
        res[ph] = {
            "n": len(lst), "T": T_tot, "S": S_tot, "H": H_tot, "G": G_tot,
            "HG": H_tot + G_tot,
            "S_ratio": S_tot / T_tot * 100 if T_tot else 0,
        }
    print(f"[{label}] steps={len(steps)} prefill={res.get('prefill', {}).get('n', 0)} decode={res.get('decode', {}).get('n', 0)}")
    for ph in ("prefill", "decode"):
        if ph not in res:
            continue
        r = res[ph]
        print(f"  {ph:7s} n={r['n']:5d} T={r['T']:9.2f}ms S={r['S']:9.2f}ms ({r['S_ratio']:5.1f}% of T) "
              f"H={r['H']:8.2f}ms G={r['G']:7.2f}ms H+G={r['HG']:8.2f}ms")
    print("  sync 明细（全 trace，self 时长 ms）:")
    for name, v in sorted(sync_by_name.items(), key=lambda kv: -kv[1])[:6]:
        print(f"    {v/1000:9.2f}  {name[:90]}")
    return res


def cmp(ra, rb):
    print("\n== 跨条件对比（B - A）==")
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


def main():
    A = sys.argv[1]
    la = sys.argv[3] if len(sys.argv) > 3 else "A"
    ra = analyze(A, la)
    if len(sys.argv) > 2:
        B = sys.argv[2]
        lb = sys.argv[4] if len(sys.argv) > 4 else "B"
        rb = analyze(B, lb)
        if ra and rb:
            cmp(ra, rb)


if __name__ == "__main__":
    main()
