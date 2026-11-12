#!/usr/bin/env python3
"""Analyze one vLLM torch-profiler trace: where does the H+G time go?

H+G here is the gap between two consecutive long ``cudaStreamSynchronize``
calls on the worker main thread: from one sync's end to the next sync's start.

    analyze_timeline_hg.py rank0.pt.trace.json.gz [options]

Outputs plain text:
  1. header        intervals, H+G per step, mode, config markers
  2. category      python_function / cpu_op / cuda_runtime shares
  3. self top N    exclusive time (children subtracted)
  4. owner top N   whole subtree attributed to the nearest ``.py`` frame

Only the Python standard library is used, so the script can be copied to any
machine that can read the trace.
"""

import argparse
import bisect
import collections
import gzip
import json
import re
import sys

_PYBIND = (
    (r"<built-in method (\w+) of Tensor object", "Tensor.{}"),
    (r"<built-in method (\w+) of numpy\.ufunc object", "numpy.ufunc.{}"),
    (r"<built-in method (\w+) of pybind11_builtins.*", "{} (pybind)"),
    (r"<built-in method (\w+) of PyCapsule object", "{} (pycapsule)"),
    (r"<built-in function (\w+)>", "{} (builtin)"),
)


def norm(name):
    if not name:
        return name
    for pattern, fmt in _PYBIND:
        m = re.match(pattern, name)
        if m:
            return fmt.format(m.group(1))
    return name


def load(path):
    with gzip.open(path, "rb") as g:
        data = json.load(g)
    return data["traceEvents"] if isinstance(data, dict) else data


def pick_main_tid(events, forced=None):
    if forced is not None:
        return forced
    launches = collections.Counter(
        e["tid"]
        for e in events
        if e.get("cat") == "cuda_runtime"
        and e.get("name") == "cudaGraphLaunch"
        and e.get("ph") == "X"
    )
    if launches:
        return launches.most_common(1)[0][0]
    syncs = collections.Counter(
        e["tid"]
        for e in events
        if e.get("cat") == "cuda_runtime"
        and e.get("name") == "cudaStreamSynchronize"
        and e.get("ph") == "X"
    )
    return syncs.most_common(1)[0][0] if syncs else None


def intervals(events, tid, sync_min_us, all_intervals, lo_us, hi_us):
    syncs = sorted(
        (e["ts"], e["ts"] + e["dur"], e["dur"])
        for e in events
        if e.get("cat") == "cuda_runtime"
        and e.get("name") == "cudaStreamSynchronize"
        and e.get("ph") == "X"
        and e.get("tid") == tid
        and e.get("dur", 0) >= sync_min_us
    )
    mode = "all"
    if not all_intervals:
        decode = [
            (syncs[i][1], syncs[i + 1][0])
            for i in range(len(syncs) - 1)
            if lo_us <= syncs[i][2] <= hi_us and lo_us <= syncs[i + 1][2] <= hi_us
        ]
        if len(decode) >= 20:
            return syncs, decode, "decode"
        mode = "all (decode intervals too few)"
    gaps = [
        (syncs[i][1], syncs[i + 1][0])
        for i in range(len(syncs) - 1)
        if 500 < (syncs[i + 1][0] - syncs[i][1]) < 50000
    ]
    return syncs, gaps, mode


def analyze(events, ivs, tid):
    ev = [
        e
        for e in events
        if e.get("ph") == "X"
        and e.get("tid") == tid
        and e.get("dur") is not None
        and e.get("cat") in ("python_function", "cpu_op", "cuda_runtime", "cuda_driver")
    ]
    ev.sort(key=lambda e: (e["ts"], -e["dur"]))
    starts = [e["ts"] for e in ev]

    self_t = collections.Counter()
    owner_t = collections.Counter()
    calls = collections.Counter()
    total = 0

    for a, b in ivs:
        total += b - a
        i = bisect.bisect_left(starts, a)
        j = i
        # include frames that started before the interval but still cover it
        while j > 0 and ev[j - 1]["ts"] + ev[j - 1]["dur"] > a and a - ev[j - 1]["ts"] < 50000:
            j -= 1
        items = []
        for k in range(j, len(ev)):
            e = ev[k]
            s = e["ts"]
            if s >= b:
                break
            en = s + e["dur"]
            if en <= a:
                continue
            items.append((max(s, a), min(en, b), (e["cat"], norm(e["name"]))))

        stack = []  # [start, end, key, child_sum, owner]
        for cs, ce, key in items:
            while stack and cs >= stack[-1][1]:
                p = stack.pop()
                v = (p[1] - p[0]) - p[3]
                self_t[p[2]] += v
                own = p[2][1] if (p[2][0] == "python_function" and ".py(" in p[2][1]) else (p[4] or "(no .py frame)")
                owner_t[own] += v
            if stack:
                stack[-1][3] += ce - cs
            parent = stack[-1][4] if stack else None
            own = parent
            if key[0] == "python_function" and ".py(" in key[1]:
                own = key[1]
            stack.append([cs, ce, key, 0.0, own])
            calls[key] += 1
        while stack:
            p = stack.pop()
            v = (p[1] - p[0]) - p[3]
            self_t[p[2]] += v
            own = p[2][1] if (p[2][0] == "python_function" and ".py(" in p[2][1]) else (p[4] or "(no .py frame)")
            owner_t[own] += v

    return self_t, owner_t, calls, total


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace", help="one rank's *.pt.trace.json.gz")
    ap.add_argument("--tid", type=int, default=None, help="worker main thread id (auto-detected)")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--sync-min-ms", type=float, default=5.0, help="a 'long' sync is at least this long")
    ap.add_argument("--decode-lo-ms", type=float, default=15.0)
    ap.add_argument("--decode-hi-ms", type=float, default=21.0)
    ap.add_argument("--all-intervals", action="store_true", help="do not restrict to decode")
    args = ap.parse_args()

    events = load(args.trace)
    tid = pick_main_tid(events, args.tid)
    if tid is None:
        sys.exit("no worker thread found; pass --tid")

    syncs, ivs, mode = intervals(
        events, tid, args.sync_min_ms * 1000, args.all_intervals,
        args.decode_lo_ms * 1000, args.decode_hi_ms * 1000,
    )
    if not ivs:
        sys.exit("no H+G intervals found; adjust --sync-min-ms or pass --all-intervals")

    self_t, owner_t, calls, total = analyze(events, ivs, tid)
    n = len(ivs)

    scope_names = collections.Counter(
        e.get("name") for e in events
        if e.get("cat") == "user_annotation" and str(e.get("name", "")).startswith("execute_context")
    )
    fastpath = sum(
        1 for e in events
        if e.get("cat") == "python_function" and "fast_build" in str(e.get("name"))
    )

    print(f"file: {args.trace}")
    print(f"main tid: {tid}  events: {len(events)}  execute_context scopes: {sum(scope_names.values())}")
    print(f"long syncs: {len(syncs)}  intervals: {n}  mode: {mode}")
    print(f"H+G per interval: {total / n:.0f} us (profiler-inflated)")
    print(f"markers: fast_build frames={fastpath}  (present => metadata fastpath active)")
    print()

    cats = collections.Counter()
    for (cat, _name), v in self_t.items():
        cats[cat] += v
    print("category (self):")
    for cat, v in cats.most_common():
        print(f"  {cat:<16} {v / n:8.0f} us/step  {100 * v / total:5.1f}%")
    print(f"  {'untracked':<16} {max(0, total - sum(cats.values())) / n:8.0f} us/step"
          f"  {100 * max(0, total - sum(cats.values())) / total:5.1f}%")
    print()

    print(f"self time top {args.top}:")
    print(f"  {'us/step':>8}  {'share':>6}  {'calls/step':>10}  function")
    for (cat, name), v in sorted(self_t.items(), key=lambda kv: -kv[1])[: args.top]:
        print(f"  {v / n:8.1f}  {100 * v / total:5.2f}%  {calls[(cat, name)] / n:10.1f}  {name}")
    print()

    print(f"owner (subtree) top {args.top}:")
    print(f"  {'us/step':>8}  {'share':>6}  owner")
    for name, v in sorted(owner_t.items(), key=lambda kv: -kv[1])[: args.top]:
        print(f"  {v / n:8.1f}  {100 * v / total:5.2f}%  {name}")


if __name__ == "__main__":
    main()
