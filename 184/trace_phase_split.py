#!/usr/bin/env python3
"""按步切分 prefill / decode，分别统计 T / S / H 及 CPU 分类。

用法: trace_phase_split.py A.json.gz [B.json.gz] [A_label] [B_label]

- 步锚点：出现次数最多的 ": execute_model" 事件
- prefill 判定：该步区间内出现 allreduce kernel，否则视为 decode
- T = 步时长（CPU 侧 execute_model 注解的 dur）
- S = 步内 GPU cat(kernel, gpu_memcpy) 的 self 总时长（按事件起始时间归属）
- H = T - S
"""
import bisect
import collections
import gzip
import json
import statistics
import sys

GPU_CATS = {"kernel", "gpu_memcpy"}


def load(path):
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return json.load(f)


def self_time(ev):
    """返回 [(ts, dur, name, cat, self_dur)]。"""
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

    step_phase = {}
    step_data = {}
    for i, (s, e) in enumerate(steps):
        j = bisect.bisect_left(ar_sorted, s)
        is_prefill = j < len(ar_sorted) and ar_sorted[j] < e
        step_phase[i] = "prefill" if is_prefill else "decode"
        step_data[i] = {"T": e - s, "cpu": collections.defaultdict(float), "gpu": 0.0}

    items = self_time(ev)
    nsteps = len(steps)
    for ts, dur, name, cat, selfd in items:
        if dur <= 0:
            continue
        end = ts + dur
        i = bisect.bisect_right(starts, ts) - 1
        k = i if i >= 0 else 0
        # 按与各步的重叠比例分摊 self time（处理跨步长事件）
        while k < nsteps and starts[k] < end:
            s, e = steps[k]
            lo = max(ts, s)
            hi = min(end, e)
            if hi > lo:
                frac = (hi - lo) / dur
                part = selfd * frac
                step_data[k]["cpu"][cat] += part
                if cat in GPU_CATS:
                    step_data[k]["gpu"] += part
            k += 1

    res = {}
    for ph in ("prefill", "decode"):
        lst = [step_data[i] for i in step_data if step_phase[i] == ph]
        n = len(lst)
        if n == 0:
            continue
        Ts = [p["T"] for p in lst]
        res[ph] = {
            "n": n,
            "T_mean": statistics.mean(Ts) / 1000,
            "T_med": statistics.median(Ts) / 1000,
            "gpu_mean": statistics.mean(p["gpu"] for p in lst) / 1000,
            "H_mean": statistics.mean(p["T"] - p["gpu"] for p in lst) / 1000,
            "cpu_op_mean": statistics.mean(p["cpu"]["cpu_op"] for p in lst) / 1000,
            "py_mean": statistics.mean(p["cpu"]["python_function"] for p in lst) / 1000,
            "rt_mean": statistics.mean(p["cpu"]["cuda_runtime"] for p in lst) / 1000,
            "T_tot": sum(Ts) / 1000,
            "S_tot": sum(p["gpu"] for p in lst) / 1000,
            "H_tot": sum(p["T"] - p["gpu"] for p in lst) / 1000,
            "cpu_op_tot": sum(p["cpu"]["cpu_op"] for p in lst) / 1000,
            "py_tot": sum(p["cpu"]["python_function"] for p in lst) / 1000,
            "rt_tot": sum(p["cpu"]["cuda_runtime"] for p in lst) / 1000,
        }
    print(f"[{label}] steps={len(steps)} prefill={res.get('prefill', {}).get('n', 0)} decode={res.get('decode', {}).get('n', 0)}")
    for ph in ("prefill", "decode"):
        if ph not in res:
            continue
        r = res[ph]
        print(f"  {ph:7s} n={r['n']:5d} T_tot={r['T_tot']:8.2f}s S_tot={r['S_tot']:8.2f}s H_tot={r['H_tot']:8.2f}s "
              f"cpu_op={r['cpu_op_tot']:7.2f}s py={r['py_tot']:7.2f}s rt={r['rt_tot']:6.2f}s")
        print(f"          per-step: T={r['T_mean']:7.2f}ms S={r['gpu_mean']:7.3f}ms H={r['H_mean']:7.2f}ms")
    return res


def cmp(ra, rb):
    print("\n== 跨条件对比（B - A）==")
    for ph in ("prefill", "decode"):
        if ph not in ra or ph not in rb:
            continue
        a, b = ra[ph], rb[ph]

        def pct(x, y):
            return (y - x) / x * 100 if x else float("nan")

        print(f"  {ph:7s} TOTAL: T {a['T_tot']:.2f}->{b['T_tot']:.2f}s ({pct(a['T_tot'], b['T_tot']):+.2f}%)  "
              f"S {a['S_tot']:.2f}->{b['S_tot']:.2f}s ({pct(a['S_tot'], b['S_tot']):+.2f}%)  "
              f"H {a['H_tot']:.2f}->{b['H_tot']:.2f}s ({pct(a['H_tot'], b['H_tot']):+.2f}%)")
        print(f"          CPU TOTAL: cpu_op {a['cpu_op_tot']:.2f}->{b['cpu_op_tot']:.2f}s ({pct(a['cpu_op_tot'], b['cpu_op_tot']):+.1f}%)  "
              f"py {a['py_tot']:.2f}->{b['py_tot']:.2f}s ({pct(a['py_tot'], b['py_tot']):+.1f}%)  "
              f"rt {a['rt_tot']:.2f}->{b['rt_tot']:.2f}s ({pct(a['rt_tot'], b['rt_tot']):+.1f}%)")


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
