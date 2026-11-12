#!/usr/bin/env python3
"""对比两份 PyTorch profiler trace：按 step 归一化的 self time（独占时间）。

用法: trace_diff.py A.json.gz B.json.gz [top_n]
- 事件名里的对象地址（at 0x...）会被剥离
- self time 按 (pid, tid) 栈式计算，父事件去掉子事件
- step 基准取 gpu_model_runner 里的 execute_model 调用次数
"""
import collections
import gzip
import json
import re
import sys

ADDR_RE = re.compile(r" at 0x[0-9a-fA-F]+")


def clean_name(n):
    return ADDR_RE.sub("", n)


def load(path):
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return json.load(f)


def self_time(data):
    """返回 (self_us[(cat,name)], calls[(cat,name)], steps, span_ms)."""
    events = data.get("traceEvents") or data.get("events") or []
    by_tid = collections.defaultdict(list)
    lo = float("inf")
    hi = float("-inf")

    for e in events:
        if e.get("ph") != "X":
            continue
        ts = e.get("ts")
        dur = e.get("dur")
        if ts is None or dur is None:
            continue
        by_tid[(e.get("pid"), e.get("tid"))].append(
            (ts, ts + dur, dur, clean_name(e.get("name", "")), e.get("cat", ""))
        )
        lo = min(lo, ts)
        hi = max(hi, ts + dur)

    self_us = collections.defaultdict(float)
    calls = collections.defaultdict(int)

    for evs in by_tid.values():
        evs.sort(key=lambda x: (x[0], -x[1]))
        stack = []  # [end, dur, child_sum, name, cat]
        for ts, end, dur, name, cat in evs:
            while stack and ts >= stack[-1][0]:
                top = stack.pop()
                key = (top[4], top[3])
                self_us[key] += top[1] - top[2]
                calls[key] += 1
                if stack:
                    stack[-1][2] += top[1]
            stack.append([end, dur, 0.0, name, cat])
        while stack:
            top = stack.pop()
            key = (top[4], top[3])
            self_us[key] += top[1] - top[2]
            calls[key] += 1
            if stack:
                stack[-1][2] += top[1]

    steps = calls.get(("cpu_op", "vllm/v1/worker/gpu_model_runner.py(4241): execute_model"), 0)
    if steps == 0:
        steps = max((c for (cat, n), c in calls.items() if n.endswith(": execute_model")), default=0)
    span_ms = (hi - lo) / 1000 if hi > lo else 0.0
    return self_us, calls, steps, span_ms


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: trace_diff.py A.json.gz B.json.gz [top_n]")
    a_path, b_path = sys.argv[1], sys.argv[2]
    top_n = int(sys.argv[3]) if len(sys.argv) > 3 else 25

    print("loading A:", a_path, flush=True)
    A_self, A_calls, A_steps, A_span = self_time(load(a_path))
    print("loading B:", b_path, flush=True)
    B_self, B_calls, B_steps, B_span = self_time(load(b_path))

    sa = A_steps or 1
    sb = B_steps or 1
    print(f"\n[A] steps={A_steps} span={A_span:.1f}ms  [B] steps={B_steps} span={B_span:.1f}ms")

    print("\n== 按 cat 的 self time（us/step）==")
    print(f"{'cat':24s} {'A':>12s} {'B':>12s} {'delta':>11s} {'diff%':>8s}")
    cats = collections.defaultdict(lambda: [0.0, 0.0])
    for (cat, n), v in A_self.items():
        cats[cat][0] += v
    for (cat, n), v in B_self.items():
        cats[cat][1] += v
    for cat, (av, bv) in sorted(cats.items(), key=lambda kv: -(kv[1][0] + kv[1][1])):
        a, b = av / sa, bv / sb
        pct = (b - a) / a * 100 if a else float("nan")
        print(f"{cat[:24]:24s} {a:12.1f} {b:12.1f} {b - a:11.1f} {pct:7.2f}%")

    def rows(keyfn):
        out = []
        for k in set(A_self) | set(B_self):
            a = A_self.get(k, 0.0) / sa
            b = B_self.get(k, 0.0) / sb
            ca = A_calls.get(k, 0)
            cb = B_calls.get(k, 0)
            out.append((keyfn(a, b), k, a, b, b - a, (b - a) / a * 100 if a else float("nan"), ca / sa, cb / sb))
        out.sort(reverse=True)
        return out

    def show(title, keyfn, n=top_n):
        print(f"\n== {title} ==")
        print(f"{'name':58s} {'A_us/step':>11s} {'B_us/step':>11s} {'delta':>10s} {'diff%':>8s} {'A_calls/st':>10s} {'B_calls/st':>10s}")
        for _, k, a, b, d, pct, ca, cb in rows(keyfn)[:n]:
            print(f"{k[1][:58]:58s} {a:11.1f} {b:11.1f} {d:10.1f} {pct:7.2f}% {ca:10.2f} {cb:10.2f}")

    show("self time 最大（B）", lambda a, b: b)
    show("B 比 A 慢最多", lambda a, b: b - a)
    show("B 比 A 快最多", lambda a, b: a - b)
    show("每步调用次数差异最大", lambda a, b: abs(b - a) * 0 + (abs(0)), n=1) if False else None


if __name__ == "__main__":
    main()
