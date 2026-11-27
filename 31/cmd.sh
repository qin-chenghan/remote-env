#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

IMAGE="${IMAGE:-local/vllm-metax:0.21.0-arm64-c500}"
PROFILE_HOST="${PROFILE_HOST:-/home/qch/qwen06_profile}"
TRACE="${TRACE:-$PROFILE_HOST/offline_bs8_in1024_out1024.json}"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### script: vllm-timeline-31-v3（只读：重新解析已导出的 870MB Perfetto JSON）"
  echo
  echo "### v2 的逐行解析没读到事件（torch 2.8 的导出不是逐行 JSON），"
  echo "### 这里用标准 json.load 重算 span / GPU busy / per-stream 空闲 gap；"
  echo "### 不跑模型、不动 trace 文件。预计 3-6 分钟（解析耗时）。"
  set +x

  echo
  echo "== 0. 前置检查（只读） =="
  ls -lh "$PROFILE_HOST" | head -10
  [[ -f "$TRACE" ]] || { echo "!! 找不到 $TRACE"; exit 2; }
  df -h /home | tail -1
  free -g | head -3

  echo
  echo "== 1. 解析 trace（只读） =="
  if command -v python3 >/dev/null 2>&1; then
      RUN=(python3)
      TARNORM="$TRACE"
  else
      RUN=(docker run --rm -i -v "$PROFILE_HOST":/profile "$IMAGE" python3)
      TARNORM="/profile/$(basename "$TRACE")"
  fi
  echo "runner=${RUN[*]}"

  "${RUN[@]}" - "$TARNORM" <<'PY'
import collections, json, sys, time, os

path = sys.argv[1]
print("file=%s size=%.1f MB" % (path, os.path.getsize(path) / 1048576))
t0 = time.time()
with open(path, "r") as f:
    d = json.load(f)
if isinstance(d, dict):
    events = d.get("traceEvents", [])
    print("top_keys=", [k for k in d.keys() if k != "traceEvents"])
else:
    events = d
print("parsed %d events in %.1f s" % (len(events), time.time() - t0))

thread_name = {}
proc_name = {}
cats = collections.Counter()
cat_dur = collections.Counter()
kern = []
kern_name_dur = collections.Counter()
kern_name_cnt = collections.Counter()
sync = collections.Counter()
sync_dur = collections.Counter()
launch = collections.Counter()
span_lo = span_hi = None
x_count = 0

for ev in events:
    ph = ev.get("ph")
    if ph == "M":
        nm = ev.get("name")
        if nm == "thread_name":
            thread_name[(ev.get("pid"), ev.get("tid"))] = (ev.get("args") or {}).get("name")
        elif nm == "process_name":
            proc_name[ev.get("pid")] = (ev.get("args") or {}).get("name")
        continue
    if ph != "X":
        continue
    ts = ev.get("ts")
    dur = ev.get("dur")
    if ts is None or dur is None:
        continue
    x_count += 1
    lo, hi = ts, ts + dur
    span_lo = lo if span_lo is None or lo < span_lo else span_lo
    span_hi = hi if span_hi is None or hi > span_hi else span_hi
    cat = ev.get("cat", "")
    cats[cat] += 1
    cat_dur[cat] += dur
    name = ev.get("name", "?")
    if cat.lower() == "kernel":
        kern.append((ts, dur, (ev.get("args") or {}).get("stream", ev.get("tid"))))
        kern_name_dur[name] += dur
        kern_name_cnt[name] += 1
    if "synchronize" in name.lower():
        sync[name] += 1
        sync_dur[name] += dur
    if "launchkernel" in name.lower():
        launch[name] += 1

span = (span_hi - span_lo) if span_lo is not None else 0
print("X events=%d span=%.3f s" % (x_count, span / 1e6 if span else 0))
print()
print("-- categories --")
for cat, cnt in cats.most_common(10):
    print("  %-22s events=%-8d dur=%.3f s" % (cat or "(none)", cnt, cat_dur[cat] / 1e6))

print()
print("-- sync / launch --")
for nm, cnt in sync.most_common(8):
    print("  %-40s n=%-7d total=%.3f s avg=%.3f ms" % (nm[:40], cnt, sync_dur[nm] / 1e6,
          sync_dur[nm] / cnt / 1000 if cnt else 0))
for nm, cnt in launch.most_common(5):
    print("  %-40s n=%-7d" % (nm[:40], cnt))

def merge_busy(iv):
    iv.sort()
    total = 0.0
    lo = hi = None
    for a, b in iv:
        if lo is None:
            lo, hi = a, b
        elif a <= hi:
            hi = max(hi, b)
        else:
            total += hi - lo
            lo, hi = a, b
    if lo is not None:
        total += hi - lo
    return total

print()
print("-- GPU kernels --")
if kern:
    busy = merge_busy([(ts, ts + dur) for ts, dur, _ in kern])
    print("kernels=%d  sum_dur=%.3f s  union_busy=%.3f s  busy=%.1f%% of span  bubble=%.3f s"
          % (len(kern), sum(d for _, d, _ in kern) / 1e6, busy / 1e6,
             100 * busy / span if span else 0, (span - busy) / 1e6))
    per_stream = collections.defaultdict(list)
    for ts, dur, st in kern:
        per_stream[st].append((ts, ts + dur))
    print("streams=%d" % len(per_stream))
    for st, iv in sorted(per_stream.items(), key=lambda kv: -merge_busy(kv[1]))[:8]:
        b = merge_busy(iv)
        iv.sort()
        gaps = []
        for (a_lo, a_hi), (b_lo, _) in zip(iv, iv[1:]):
            g = b_lo - a_hi
            if g > 0:
                gaps.append((a_hi, g))
        gt = sum(g for _, g in gaps)
        gm = max((g for _, g in gaps), default=0)
        big = [(t, g) for t, g in gaps if g >= 500]
        big.sort(key=lambda x: -x[1])
        print("  stream %-8s kernels=%-6d busy=%.3f s idle=%.3f s max_gap=%.2f ms gaps>=0.5ms=%d"
              % (str(st), len(iv), b / 1e6, gt / 1e6, gm / 1000, len(big)))
        for t, g in big[:3]:
            print("      gap %.2f ms at t+%.3f s" % (g / 1000, (t - span_lo) / 1e6))
    print()
    print("-- top kernel names by total dur --")
    for nm, d in kern_name_dur.most_common(15):
        print("  %-64s %.3f s n=%d" % (nm[:64], d / 1e6, kern_name_cnt[nm]))
else:
    print("没有 kernel 事件")

names = collections.Counter()
for (pid, tid), nm in thread_name.items():
    if nm:
        names[nm] += 1
print()
print("-- trace threads (first 15 by pid/tid) --")
for (pid, tid), nm in list(thread_name.items())[:15]:
    print("  pid=%s tid=%s name=%s" % (pid, tid, nm))
PY

  echo
  echo "== 2. 结束后（只读） =="
  ls -lh "$PROFILE_HOST" | head -6

  echo
  echo "### 完成：trace 解析"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
