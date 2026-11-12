#!/usr/bin/env python3
"""把 allreduce kernel 归属到 execute_model 步，判断 prefill / decode 分布。

用法: trace_phase.py trace.json.gz [label]
输出: 每步的 allreduce 次数/总时长分布、按步时长排序的 Top、按输出特征分桶。
"""
import bisect
import collections
import gzip
import json
import sys


def load(path):
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return json.load(f)


def main():
    path = sys.argv[1]
    label = sys.argv[2] if len(sys.argv) > 2 else path.split("/")[-3]
    data = load(path)
    ev = data.get("traceEvents") or data.get("events") or []

    # 收集所有含 execute_model 的候选事件，取出现次数最多的那个名字作为步锚点
    cand = collections.defaultdict(list)
    ar_total = 0.0
    ar_all = []         # (ts, dur)

    for e in ev:
        if e.get("ph") != "X":
            continue
        name = e.get("name", "")
        ts = e.get("ts")
        dur = e.get("dur") or 0
        if ts is None:
            continue
        if ": execute_model" in name and e.get("cat") != "kernel":
            cand[name].append((ts, ts + dur))
        if "allreduce" in name and e.get("cat") == "kernel":
            ar_all.append((ts, dur))

    print(f"[{label}] execute_model 候选:")
    for n, lst in sorted(cand.items(), key=lambda kv: -len(kv[1]))[:5]:
        print(f"   {len(lst):6d}  {n}")

    steps = []
    if cand:
        best = max(cand.values(), key=len)
        steps = sorted(best)
    starts = [s[0] for s in steps]
    print(f"[{label}] 采用步数={len(steps)}；allreduce kernel 数={len(ar_all)}")

    ar = collections.defaultdict(list)
    if not steps:
        print("  没有找到步锚点，无法归属")
        return
    # 每个 kernel 归属到"启动时最后一个已开始的步"
    for ts, dur in ar_all:
        i = bisect.bisect_right(starts, ts) - 1
        if i >= 0:
            ar[i].append(dur)
        ar_total += dur

    per_step = []
    for i in range(len(steps)):
        durs = ar.get(i, [])
        d = steps[i][1] - steps[i][0]
        per_step.append((sum(durs), len(durs), d, i))

    with_ar = [p for p in per_step if p[0] > 0]
    print(f"  有 allreduce 的步数={len(with_ar)} ({len(with_ar)/max(1,len(steps))*100:.1f}%)")
    if with_ar:
        print(f"  每步（有 allreduce 的步）均值: calls={sum(p[1] for p in with_ar)/len(with_ar):.2f} "
              f"time={sum(p[0] for p in with_ar)/len(with_ar):.1f}us")
    print(f"  全部步均值: calls={sum(p[1] for p in per_step)/max(1,len(steps)):.2f} "
          f"time={sum(p[0] for p in per_step)/max(1,len(steps)):.1f}us")
    print(f"  allreduce 总时长={ar_total/1000:.1f}ms")

    # 集中度：按每步 allreduce 时长降序累计
    srt = sorted(per_step, key=lambda p: -p[0])
    tot = sum(p[0] for p in srt) or 1
    cum = 0
    for k, p in enumerate(srt[:20]):
        cum += p[0]
        print(f"    top{k+1:2d} step#{p[3]:5d} ar_time={p[0]:9.1f}us calls={p[1]:4d} "
              f"step_dur={p[2]/1000:8.2f}ms  cum={cum/tot*100:5.1f}%")
    # 前 N 步占比
    for n in (5, 10, 20, 50, 100):
        c = sum(p[0] for p in srt[:n])
        print(f"  top{n:3d} 步占 allreduce 总时长: {c/tot*100:5.1f}%")

    # 步时长分布（用于识别 prefill：步明显更长）
    durs = sorted(p[2] for p in per_step)
    print(f"  step duration: min={durs[0]/1000:.1f}ms p50={durs[len(durs)//2]/1000:.1f}ms "
          f"p95={durs[int(len(durs)*0.95)]/1000:.1f}ms max={durs[-1]/1000:.1f}ms")
    long_steps = [p for p in per_step if p[2] > durs[len(durs)//2] * 3]
    print(f"  长步（>3x p50）数={len(long_steps)}，其中带 allreduce 的={sum(1 for p in long_steps if p[0]>0)}")

    # kernel 单次耗时分布
    buckets = collections.Counter()
    for _, d in ar_all:
        if d < 10:
            buckets["<10us"] += 1
        elif d < 100:
            buckets["10-100us"] += 1
        elif d < 1000:
            buckets["100us-1ms"] += 1
        else:
            buckets[">=1ms"] += 1
    print(f"  allreduce 单次耗时分布: {dict(buckets)}")


if __name__ == "__main__":
    main()
