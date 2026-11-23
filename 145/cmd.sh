#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。等待 py312 1024/1024 预热结束，报告结果与缓存增量。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
TOOLS=/home/huawei_ts_program/litehost_perf_opt
TEST_ID=prime_py312_1024
LOG=/tmp/run_${TEST_ID}.log
CACHE=/home/huawei_ts_program/inductor_cache_py312

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 等待完成（最多 12 分钟）=="
  for i in $(seq 1 24); do
    if docker exec "$C" test -f "$TOOLS/vllmBench/$TEST_ID/summary.csv" 2>/dev/null; then
      echo "summary.csv 已生成"; break
    fi
    [ "$i" -eq 1 ] && echo "等待中（30s/轮）"
    sleep 30
  done

  echo "== 2. 日志尾部 =="
  docker exec "$C" bash -lc "tail -12 $LOG 2>/dev/null"

  echo "== 3. 结果 =="
  docker exec "$C" bash -lc "cut -d, -f2,4,5,6,8,11 $TOOLS/vllmBench/$TEST_ID/summary.csv 2>/dev/null"

  echo "== 4. 缓存增量 =="
  docker exec "$C" bash -lc "
    echo \"files=\$(find $CACHE -name '*.py' 2>/dev/null | wc -l)\"
    du -sh $CACHE 2>/dev/null
    for f in $CACHE/*/*.py; do head -1 \$f 2>/dev/null; done | sort | uniq -c | head -6
  " 2>&1 | head -12

  echo "== 5. 残留 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm[.]entrypoints|bench_driver" | grep -v pgrep || echo none'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "ports free"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
