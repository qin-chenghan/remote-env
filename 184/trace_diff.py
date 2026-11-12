#!/usr/bin/env python3
"""对比两份 PyTorch profiler trace：按 step 归一化的函数/类别 self time。

用法: trace_diff.py A.json.gz B.json.gz [top_n]
输出: 步骤数、span、按 cat 汇总、按 name 的 Top 差异。
"""
import collections
import gzip
import json
import sys


def load(path):
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return json.load(f)


def aggregate(data):
    events = data.get("traceEvents") or data.get("events") or []
    steps = 0
    span_lo = float("inf")
    span_hi = float("-inf")
    cats = collections.defaultdict(lambda: [0.0, 0])
    names = collections.defaultdict(lambda: [0.0, 0])
    for e in events:
        ts = e.get("ts")
        if ts is not None:
            span_lo = min(span_lo, ts)
            span_hi = max(span_hi, ts + (e.get("dur") or 0))
        if e.get("ph") != "X":
            continue
        name = e.get("name", "")
        cat = e.get("cat", "")
        dur = e.get("dur") or 0
        cats[cat][0] += dur
        cats[cat][1] += 1
        if name.startswith("ProfilerStep"):
            steps += 1
        else:
            names[name][0] += dur
            names[name][1] += 1
    return {
        "steps": steps,
        "span": (span_lo, span_hi),
        "cats": cats,
        "names": names,
        "total_events": len(events),
    }


def per_step(agg):
    s = agg["steps"] or 1
    return s


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: trace_diff.py A.json.gz B.json.gz [top_n]")
    a_path, b_path = sys.argv[1], sys.argv[2]
    top_n = int(sys.argv[3]) if len(sys.argv) > 3 else 25

    print("loading A:", a_path, flush=True)
    A = aggregate(load(a_path))
    print("loading B:", b_path, flush=True)
    B = aggregate(load(b_path))

    for tag, agg in (("A(4k)", A), ("B(64k)", B)):
        lo, hi = agg["span"]
        span_ms = (hi - lo) / 1000 if hi > lo else 0
        print(f"\n[{tag}] steps={agg['steps']} events={agg['total_events']} "
              f"span={span_ms:.1f}ms")

    sa = A["steps"] or 1
    sb = B["steps"] or 1
    print(f"\n== 每 step 归一化（A 除以 {sa}，B 除以 {sb}）==")
    print(f"{'cat':28s} {'A_us/step':>12s} {'B_us/step':>12s} {'diff%':>9s}")
    cats = sorted(set(A["cats"]) | set(B["cats"]),
                  key=lambda c: -max(A["cats"][c][0], B["cats"][c][0]))
    for c in cats:
        av = A["cats"][c][0] / sa
        bv = B["cats"][c][0] / sb
        pct = (bv - av) / av * 100 if av else float("nan")
        print(f"{c[:28]:28s} {av:12.1f} {bv:12.1f} {pct:8.2f}%")

    def table(title, key):
        print(f"\n== {title} ==")
        print(f"{'name':60s} {'A_us/step':>11s} {'B_us/step':>11s} {'delta':>10s} {'diff%':>8s}")
        rows = []
        for n in set(A["names"]) | set(B["names"]):
            da = A["names"][n][0] / sa
            db = B["names"][n][0] / sb
            rows.append((key(da, db), n, da, db, db - da, (db - da) / da * 100 if da else float("nan")))
        rows.sort(reverse=True)
        for _, n, da, db, d, pct in rows[:top_n]:
            print(f"{n[:60]:60s} {da:11.1f} {db:11.1f} {d:10.1f} {pct:7.2f}%")

    table("按 B 绝对耗时排序", lambda da, db: db)
    table("按差值排序（B 慢于 A 在前）", lambda da, db: db - da)
    table("按差值排序（B 快于 A 在前）", lambda da, db: da - db)


if __name__ == "__main__":
    main()
