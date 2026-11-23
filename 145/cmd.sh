#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：检查 vllm 容器是否空闲；空闲则用 py312 预热 1024/1024 的 inductor 缓存。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
TOOLS=/home/huawei_ts_program/litehost_perf_opt
MODEL=/home/model/Qwen3-32B-W8A8
CACHE=/home/huawei_ts_program/inductor_cache_py312
TEST_ID=prime_py312_1024
LOG=/tmp/run_${TEST_ID}.log
CASES=/tmp/cases_1024.txt

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 是否有人在跑 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm[.]entrypoints[.]openai[.]api_server|bench_driver" | grep -v pgrep || echo "no server/bench"'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 free"

  if docker exec "$C" bash -lc 'pgrep -f "vllm[.]entrypoints[.]openai[.]api_server" >/dev/null 2>&1' \
     || ss -ltn 2>/dev/null | grep -qE ':(8948|8848)\b'; then
    echo "!! 容器里有服务在跑，不启动预热"
  else
    echo "== 2. 预热前缓存 =="
    docker exec "$C" bash -lc "echo files=\$(find $CACHE -name '*.py' 2>/dev/null | wc -l)"

    echo "== 3. 准备 cases 文件并启动 py312 预热 =="
    docker exec "$C" bash -lc "printf '1024 1024\n' > $CASES; cat $CASES"
    docker exec -d "$C" bash -lc "cd $TOOLS && \
      CASES_FILE=$CASES TEST_ID=$TEST_ID HOST_MEASURE=off MODEL_PATH=$MODEL \
      nohup bash vllmBench_lite_base_mock_py312.sh > $LOG 2>&1"
    sleep 30
    docker exec "$C" bash -lc "grep -E 'PREFIX=|inductor_cache=|case 最终结果|====' $LOG 2>/dev/null | head -4; tail -3 $LOG 2>/dev/null"

    echo "== 4. 后续 =="
    echo "日志：$LOG"
    echo "结果：$TOOLS/vllmBench/$TEST_ID"
    echo "缓存：$CACHE"
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
