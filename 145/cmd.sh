#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：用已预热的缓存再跑一遍 128/128，实证零编译（只读校验）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
TOOLS=/home/huawei_ts_program/litehost_perf_opt
MODEL=/home/model/Qwen3-32B-W8A8
TEST_ID=confirm_py312_128
LOG=/tmp/run_${TEST_ID}.log
CACHE=/home/huawei_ts_program/inductor_cache_py312

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 前置 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm.entrypoints.openai.api_server|bench_driver" | grep -v pgrep || echo "no server/bench"'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 free"
  echo "cache before = $(docker exec "$C" bash -lc "find $CACHE -name '*.py' | wc -l")"

  echo "== 2. 启动确认跑（TORCHDYNAMO_VERBOSE=1）=="
  docker exec -d "$C" bash -lc "cd $TOOLS && \
    TEST_ID=$TEST_ID HOST_MEASURE=off MODEL_PATH=$MODEL TORCHDYNAMO_VERBOSE=1 \
    nohup bash vllmBench_lite_base_mock_py312.sh > $LOG 2>&1"
  sleep 25
  docker exec "$C" bash -lc "grep -E 'inductor_cache=|PREFIX=' $LOG 2>/dev/null | head -3"

  echo "== 3. 等待完成（最多 6 分钟）=="
  for i in $(seq 1 24); do
    if docker exec "$C" test -f "$TOOLS/vllmBench/$TEST_ID/summary.csv" 2>/dev/null; then
      echo "summary.csv 已生成"; break
    fi
    [ "$i" -eq 1 ] && echo "等待中（15s/轮）"
    sleep 15
  done

  echo "== 4. 零编译证据 =="
  echo "-- Compiling 计数（应为 0）--"
  docker exec "$C" bash -lc "grep -c 'Compiling' $LOG 2>/dev/null || echo 0"
  echo "-- 缓存文件数（应与预热后相同）--"
  docker exec "$C" bash -lc "echo \"after=\$(find $CACHE -name '*.py' | wc -l)\""
  echo "-- 日志里的 inductor_cache 行 --"
  docker exec "$C" bash -lc "grep 'inductor_cache=' $LOG | head -2"

  echo "== 5. 结果与残留 =="
  docker exec "$C" bash -lc "cut -d, -f2,6,8,11 $TOOLS/vllmBench/$TEST_ID/summary.csv 2>/dev/null; tail -3 $LOG"
  docker exec "$C" bash -lc 'pgrep -af "vllm.entrypoints.openai.api_server|bench_driver" | grep -v pgrep || echo "no leftover"'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "ports free"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
