#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：为 128/128 预热 inductor cache（只跑负载，不出 trace，不改任何文件）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
TOOLS=/home/huawei_ts_program/litehost_perf_opt
MODEL=/home/model/Qwen3-32B-W8A8
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

  echo "== 1. 前置检查（不打扰正在跑的活）=="
  docker ps --filter "name=$C" --format '{{.Names}} {{.Status}}'
  docker exec "$C" bash -lc 'pgrep -af "vllm.entrypoints.openai.api_server|bench_driver" | grep -v pgrep || echo "no server/bench running"'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 free"
  docker exec "$C" bash -lc "test -f $MODEL/config.json && echo model-ok; test -x $TOOLS/vllmBench_lite_base_mock_py312.sh && echo script-ok"
  free -g | sed -n 2p
  df -h /home | tail -1

  echo "== 2. 预热前缓存状态 =="
  docker exec "$C" bash -lc "ls -d $CACHE 2>/dev/null && find $CACHE -name '*.py' | wc -l || echo '0 files (cold cache)'"
  docker exec "$C" bash -lc "du -sh $CACHE 2>/dev/null || echo 'no cache dir'"

  echo "== 3. 启动 128/128 预热（后台，HOST_MEASURE=off，无 trace）=="
  echo "TEST_ID=$TEST_ID"
  docker exec -d "$C" bash -lc "cd $TOOLS && \
    TEST_ID=$TEST_ID HOST_MEASURE=off MODEL_PATH=$MODEL \
    nohup bash vllmBench_lite_base_mock_py312.sh > $LOG 2>&1"
  sleep 25
  echo "-- 启动 25 秒后 --"
  docker exec "$C" bash -lc "tail -8 $LOG 2>/dev/null || echo '(日志未出现)'"

  echo "== 4. 后续 =="
  echo "日志（容器内）：$LOG"
  echo "结果目录（容器内）：$TOOLS/vllmBench/$TEST_ID"
  echo "跑完后再跑一次本文件即可查看缓存增量"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
