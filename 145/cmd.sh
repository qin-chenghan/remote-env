#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：同步四份脚本（逐文件）→ 检查预热状态；没有在跑就启动 py311 预热。
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

  echo "== 1. 逐文件同步（宿主 → 容器）=="
  for f in $FILES; do
    cp -f "$SRC/$f" "$TOOLS/$f" || exit 1
    docker cp "$TOOLS/$f" "$C":"$TOOLS/$f" || exit 1
    echo "synced: $f"
  done
  docker exec "$C" chmod +x "$TOOLS"/vllmBench_lite_base_*.sh

  echo "== 2. 四份脚本关键改动确认（容器内）=="
  for f in $FILES; do
    echo "-- $f"
    docker exec "$C" bash -lc "bash -n $TOOLS/$f && echo syntax-ok"
    docker exec "$C" bash -lc "grep -c 'SERVER_WAIT_TIMEOUT' $TOOLS/$f; grep -o 'TORCHINDUCTOR_CACHE_DIR=[^}]*' $TOOLS/$f | head -1"
  done

  echo "== 3. 状态 =="
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 free"
  docker exec "$C" bash -lc "echo \"py311 cache files=\$(find $CACHE -name '*.py' 2>/dev/null | wc -l)\""

  echo "== 4. 预热状态 / 启动 =="
  if docker exec "$C" bash -lc 'pgrep -f "vllm[.]entrypoints[.]openai[.]api_server" >/dev/null 2>&1'; then
    echo "已有服务在跑，跳过启动"
    docker exec "$C" bash -lc "grep -E 'inductor_cache=|全部完成' $LOG 2>/dev/null | head -2; tail -3 $LOG 2>/dev/null"
  elif docker exec "$C" test -f "$TOOLS/vllmBench/$TEST_ID/summary.csv" 2>/dev/null; then
    echo "该 TEST_ID 已完成，不再启动"
    docker exec "$C" bash -lc "cut -d, -f2,6,8,11 $TOOLS/vllmBench/$TEST_ID/summary.csv 2>/dev/null"
  else
    echo "启动 py311 预热（HOST_MEASURE=off，无等待上限）"
    docker exec -d "$C" bash -lc "cd $TOOLS && \
      TEST_ID=$TEST_ID HOST_MEASURE=off MODEL_PATH=$MODEL \
      nohup bash vllmBench_lite_base_mock.sh > $LOG 2>&1"
    sleep 30
    docker exec "$C" bash -lc "grep -E 'PREFIX=|inductor_cache=' $LOG 2>/dev/null | head -3; tail -3 $LOG 2>/dev/null"
  fi

  echo "== 5. 后续 =="
  echo "日志：$LOG（容器内）"
  echo "缓存：$CACHE（容器内）"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
