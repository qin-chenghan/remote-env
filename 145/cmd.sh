#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。验证固定目录的 128/128 预热结果。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
TOOLS=/home/huawei_ts_program/litehost_perf_opt
TEST_ID=prime_py312_128_cached
LOG=/tmp/run_${TEST_ID}.log
CACHE=/home/huawei_ts_program/inductor_cache_py312

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 是否完成 =="
  docker exec "$C" bash -lc "
    [ -f $TOOLS/vllmBench/$TEST_ID/summary.csv ] && echo done || echo running
    tail -6 $LOG 2>/dev/null
  " 2>&1 | tail -9

  echo "== 2. 吞吐 =="
  docker exec "$C" bash -lc "cut -d, -f2,5,6,8,11 $TOOLS/vllmBench/$TEST_ID/summary.csv 2>/dev/null"

  echo "== 3. 新缓存目录 =="
  docker exec "$C" bash -lc "
    echo \"new cache files=\$(find $CACHE -name '*.py' 2>/dev/null | wc -l)\"
    du -sh $CACHE 2>/dev/null
    echo '-- AOT ID 分布 --'
    for f in $CACHE/*/*.py; do head -1 \$f 2>/dev/null; done | sort | uniq -c | head -8
  " 2>&1 | head -14

  echo "== 4. 旧 /tmp 缓存（保留未动）=="
  docker exec "$C" bash -lc "echo \"/tmp files=\$(find /tmp/torchinductor_root -name '*.py' 2>/dev/null | wc -l)\""

  echo "== 5. 残留与端口 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm.entrypoints.openai.api_server|bench_driver" | grep -v pgrep || echo "no leftover"'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 free"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
