#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  echo "== 1. STEPS / WARMUP_STEPS 定义 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
grep -rn "STEPS" "$P"/*.cpp "$P"/*.h 2>/dev/null | grep -iE "define|const|=" | head -10
' 2>&1 | head -15

  echo "== 2. 交替测量 3 轮（绑 cpu0）=="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
cd "$P" || exit 1
: > /tmp/res_base.txt
: > /tmp/res_neon.txt
for i in 1 2 3; do
  taskset -c 0 ./fusion.unittest.bak_before_neon 1 2>&1 | grep -E "warmup .*Step +9 " | tail -1 >> /tmp/res_base.txt
  taskset -c 0 ./fusion.unittest                 1 2>&1 | grep -E "warmup .*Step +9 " | tail -1 >> /tmp/res_neon.txt
done

echo "-- 基线 3 轮 --"; cat /tmp/res_base.txt
echo "-- 优化 3 轮 --"; cat /tmp/res_neon.txt

echo "-- 统计 --"
python3 - <<"PY"
import re
for name, f in (("base", "/tmp/res_base.txt"), ("neon", "/tmp/res_neon.txt")):
    ms, bw = [], []
    for line in open(f):
        m = re.search(r"Target Time is (\S+) ms Bandwidth is (\S+) MB/s", line)
        if m:
            ms.append(float(m.group(1)))
            bw.append(float(m.group(2)))
    if ms:
        print("%s: n=%d mean_ms=%.3f min_ms=%.3f mean_bw=%.1f" %
              (name, len(ms), sum(ms)/len(ms), min(ms), sum(bw)/len(bw)))
    else:
        print("%s: no sample" % name)
PY
' 2>&1 | head -30

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
