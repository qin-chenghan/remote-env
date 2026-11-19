#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：在 145 上跑第一次 mock bench（torch profiler 口径，128/128，与 32 同配置）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TOOLS=/home/huawei_ts_program/litehost_perf_opt
MODEL=/home/model/Qwen3-32B-W8A8
MOCK=/home/qch/mock_vllm
CONTAINER=corex5-py311-mock
TEST_ID="mock145_$(date +%H%M)"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 前置检查 =="
  docker ps --filter "name=$CONTAINER" --format '{{.Names}} {{.Status}}' | grep -q Up \
    || { echo "!! 容器没在跑"; exit 3; }
  [ -f "$MODEL/config.json" ] || { echo "!! 缺模型"; exit 3; }
  [ -f "$TOOLS/vllmBench_lite_base_timeline.sh" ] || { echo "!! 缺 harness"; exit 3; }
  [ -f "$MOCK/mock_ix.so" ] || { echo "!! 缺 mock_ix.so"; exit 3; }
  if ss -ltn 2>/dev/null | grep -q ':8948 '; then
    echo "!! 8948 被占用，可能已有服务在跑"; exit 5
  fi
  free -g | sed -n 2p
  df -h /home | tail -1

  echo "== 2. 启动 bench（后台，日志留在 $TOOLS/vllmBench/$TEST_ID）=="
  echo "TEST_ID=$TEST_ID"
  docker exec -d "$CONTAINER" bash -lc "cd $TOOLS && \
    MODEL_PATH=$MODEL MOCK_DIR=$MOCK TEST_ID=$TEST_ID \
    nohup bash vllmBench_lite_base_timeline.sh \
    > /home/qch/transfer/run_$TEST_ID.log 2>&1"
  sleep 25
  echo "-- 启动 25 秒后的日志 --"
  tail -12 "/home/qch/transfer/run_$TEST_ID.log" 2>/dev/null || echo "(日志未出现)"
  echo "-- 服务进程 --"
  docker exec "$CONTAINER" bash -lc 'pgrep -af "vllm.entrypoints.openai.api_server" | head -2' 2>/dev/null

  echo "== 3. 后续查看 =="
  echo "日志：/home/qch/transfer/run_$TEST_ID.log"
  echo "结果：$TOOLS/vllmBench/$TEST_ID/summary.csv"
  echo "trace：$TOOLS/vllmBench/$TEST_ID/timeline/"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
