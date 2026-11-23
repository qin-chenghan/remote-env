#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。分析 145 上 test / test311 的 litehost per-scope 数据（prefill/decode 时间结构）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
VB=/home/huawei_ts_program/litehost_perf_opt/vllmBench

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 定位 rank0 scope CSV =="
  for d in test test311; do
    docker exec "$C" bash -lc "ls -l $VB/$d/litehost/*/rank0_pid*.csv 2>/dev/null | head -2" 2>&1
  done

  echo "== 2. 写分析脚本 =="
  docker exec "$C" bash -lc 'cat > /tmp/analyze_scopes.py <<"PY"
import csv, sys, collections, re

path = sys.argv[1]
rows = list(csv.DictReader(open(path)))
t0 = float(rows[0]["start_ns"])
cats = collections.Counter()
tl = []
durs = collections.defaultdict(list)
for r in rows:
    m = re.match(r"execute_context_(\d+)\((\d+)\)_generation_(\d+)\((\d+)\)", r["scope"])
    if not m:
        cats["other"] += 1
        continue
    cr, ct, gr, gt = map(int, m.groups())
    if cr == 0 and gr > 0:
        k = "decode"
    elif gr == 0 and cr > 0:
        k = "prefill"
    elif cr > 0 and gr > 0:
        k = "mixed"
    else:
        k = "other"
    cats[k] += 1
    dur = (float(r["end_ns"]) - float(r["start_ns"])) / 1e6
    durs[k].append(dur)
    tl.append(((float(r["start_ns"]) - t0) / 1e6, k, cr, ct, gr, gt))

print("rows:", len(rows))
print("categories:", dict(cats))
for k in ("prefill", "mixed", "decode"):
    if durs[k]:
        print(f"{k}: n={len(durs[k])} mean_dur={sum(durs[k])/len(durs[k]):.2f}ms max={max(durs[k]):.2f}ms")

print("time buckets (0.5s): prefill/mixed/decode")
b = collections.defaultdict(collections.Counter)
for off, k, *_ in tl:
    b[int(off // 500)][k] += 1
for i in sorted(b):
    c = b[i]
    pre=c["prefill"]; mix=c["mixed"]; dec=c["decode"]
    print("  %.1f-%.1fs  prefill=%3d mixed=%3d decode=%4d" % (i*0.5, i*0.5+0.5, pre, mix, dec))

print("first 15 scopes:")
for off, k, cr, ct, gr, gt in sorted(tl)[:15]:
    print(f"  +{off:8.1f}ms {k:8s} ctx={cr}({ct}) gen={gr}({gt})")
PY
echo written'

  echo "== 3. 逐个分析 =="
  for d in test test311; do
    f=$(docker exec "$C" bash -lc "ls $VB/$d/litehost/*/rank0_pid*.csv 2>/dev/null | head -1")
    echo "===== $d  ($f)"
    if [ -n "$f" ]; then
      docker exec "$C" /usr/local/bin/python3 /tmp/analyze_scopes.py "$f" 2>&1 | head -40
    else
      echo "无 rank0 csv"
    fi
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
