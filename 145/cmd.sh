#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。确认 128/128 预热完成、缓存增量，并检查没有残留进程/端口。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
TOOLS=/home/huawei_ts_program/litehost_perf_opt
TEST_ID=prime_py312_128
LOG=/tmp/run_${TEST_ID}.log
CACHE=/tmp/torchinductor_root

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 是否跑完 =="
  docker exec "$C" bash -lc "
    if [ -f $TOOLS/vllmBench/$TEST_ID/summary.csv ]; then echo 'summary.csv 已生成'; else echo '尚未完成'; fi
    tail -12 $LOG 2>/dev/null
  " 2>&1 | tail -16

  echo "== 2. 吞吐结果 =="
  docker exec "$C" bash -lc "cat $TOOLS/vllmBench/$TEST_ID/summary.csv 2>/dev/null | cut -d, -f2,5,6,8,11"

  echo "== 3. 缓存现状 =="
  docker exec "$C" bash -lc "
    echo \"py files: \$(find $CACHE -name '*.py' 2>/dev/null | wc -l)\"
    du -sh $CACHE 2>/dev/null
    echo '-- AOT ID 分布 --'
    for f in $CACHE/*/*.py; do head -1 \$f 2>/dev/null; done | sort | uniq -c | head -8
  " 2>&1 | head -14

  echo "== 4. 残留进程与端口 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm.entrypoints.openai.api_server|bench_driver" | grep -v pgrep || echo "no leftover processes"'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 free"

  echo "== 5. 产物大小 =="
  docker exec "$C" bash -lc "du -sh $TOOLS/vllmBench/$TEST_ID 2>/dev/null; ls $TOOLS/vllmBench/$TEST_ID 2>/dev/null | head -6"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
