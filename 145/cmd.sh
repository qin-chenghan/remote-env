#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：同步新脚本（超时可配、py311 缓存固定）→ 用 py311 预热 128/128。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

SRC="$DIR/../litehost_toolkit"
TOOLS=/home/huawei_ts_program/litehost_perf_opt
C=vllm
MODEL=/home/model/Qwen3-32B-W8A8
TEST_ID=prime_py311_128
LOG=/tmp/run_${TEST_ID}.log
CACHE=/home/huawei_ts_program/inductor_cache_py311
FILES="vllmBench_lite_base_mock.sh vllmBench_lite_base_timeline.sh vllmBench_lite_base_mock_py312.sh vllmBench_lite_base_timeline_py312.sh"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 同步脚本（宿主 + 容器）=="
  cp -f "$SRC"/$FILES "$TOOLS"/
  chmod +x "$TOOLS"/vllmBench_lite_base_*.sh
  for f in $FILES; do docker cp "$TOOLS/$f" "$C":"$TOOLS/$f"; done
  docker exec "$C" chmod +x "$TOOLS"/vllmBench_lite_base_*.sh

  echo "== 2. 关键改动确认（容器内）=="
  docker exec "$C" bash -lc "
    grep -n 'SERVER_WAIT_TIMEOUT' $TOOLS/vllmBench_lite_base_mock.sh | head -3
    grep -n 'TORCHINDUCTOR_CACHE_DIR\|VLLM_RPC_TIMEOUT' $TOOLS/vllmBench_lite_base_mock.sh | head -4
  "
  docker exec "$C" bash -lc "bash -n $TOOLS/vllmBench_lite_base_mock.sh && echo mock-syntax-ok"
  docker exec "$C" bash -lc "bash -n $TOOLS/vllmBench_lite_base_timeline.sh && echo timeline-syntax-ok"

  echo "== 3. 前置检查 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm[.]entrypoints[.]openai[.]api_server|bench_driver" | grep -v pgrep || echo "no server/bench"'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 free"
  docker exec "$C" bash -lc "echo \"py311 cache before=\$(find $CACHE -name '*.py' 2>/dev/null | wc -l)\""

  echo "== 4. 启动 py311 预热（128/128，HOST_MEASURE=off，无 trace，不设等待上限）=="
  docker exec -d "$C" bash -lc "cd $TOOLS && \
    TEST_ID=$TEST_ID HOST_MEASURE=off MODEL_PATH=$MODEL \
    nohup bash vllmBench_lite_base_mock.sh > $LOG 2>&1"
  sleep 30
  docker exec "$C" bash -lc "
    grep -E 'PREFIX=|inductor_cache=|SERVER_WAIT' $LOG 2>/dev/null | head -3
    tail -3 $LOG 2>/dev/null
  "

  echo "== 5. 后续 =="
  echo "日志：$LOG（容器内）"
  echo "缓存：$CACHE（容器内）"
  echo "跑完后再执行本文件可查看缓存增量；如需上限可传 SERVER_WAIT_TIMEOUT=3600"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
