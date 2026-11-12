#!/usr/bin/env python3
"""比较两次运行的 prefill/decode 划分差异。

用法: trace_phase_delta.py A.json.gz B.json.gz
输出: A 判 prefill 而 B 判 decode 的步（反之亦然），附步时长与步内 allreduce 数。
"""
import bisect
import collections
import gzip
import json
import sys


def load(path):
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return json.load(f)


def classify(path):
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
    ar_s = sorted(ar)
    pre = {}
    for i, (s, e) in enumerate(steps):
        j = bisect.bisect_left(ar_s, s)
        n_ar = 0
        while j < len(ar_s) and ar_s[j] < e:
            n_ar += 1
            j += 1
        pre[i] = (n_ar > 0, e - s, n_ar)
    return steps, pre


def main():
    A, B = sys.argv[1], sys.argv[2]
    sa, pa = classify(A)
    sb, pb = classify(B)
    print(f"A steps={len(sa)} B steps={len(sb)}")
    n = min(len(sa), len(sb))

    for tag, x, y in (("A-prefill / B-decode", pa, pb), ("A-decode / B-prefill", pb, pa)):
        print(f"\n== {tag} ==")
        cnt = 0
        for i in range(n):
            if x[i][0] and not y[i][0]:
                cnt += 1
                print(f"  step#{i:5d} dur={x[i][1]/1000:7.2f}ms ar_calls={x[i][2]:4d} "
                      f"(other: dur={y[i][1]/1000:7.2f}ms ar_calls={y[i][2]:4d})")
        print(f"  共 {cnt} 步")
        if cnt and cnt <= 20:
            durs = [x[i][1] / 1000 for i in range(n) if x[i][0] and not y[i][0]]
            print(f"  这些步的时长: min={min(durs):.2f} max={max(durs):.2f} 均值={sum(durs)/len(durs):.2f}ms")


if __name__ == "__main__":
    main()
