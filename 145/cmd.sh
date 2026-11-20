#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：同步固定缓存目录的 py312 脚本 → 用新目录跑 128/128 预热（5 分钟）。
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
TEST_ID=prime_py312_128_cached
LOG=/tmp/run_${TEST_ID}.log
CACHE=/home/huawei_ts_program/inductor_cache_py312
FILES="vllmBench_lite_base_mock_py312.sh vllmBench_lite_base_timeline_py312.sh"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 同步脚本（宿主 + 容器）=="
  cp -f "$SRC"/vllmBench_lite_base_mock_py312.sh "$SRC"/vllmBench_lite_base_timeline_py312.sh "$TOOLS"/
  chmod +x "$TOOLS"/vllmBench_lite_base_*_py312.sh
  for f in $FILES; do docker cp "$TOOLS/$f" "$C":"$TOOLS/$f"; done
  docker exec "$C" chmod +x "$TOOLS"/vllmBench_lite_base_*_py312.sh
  docker exec "$C" bash -lc "grep -n 'TORCHINDUCTOR_CACHE_DIR\|inductor_cache=' $TOOLS/vllmBench_lite_base_mock_py312.sh | head -4"
  docker exec "$C" bash -lc "bash -n $TOOLS/vllmBench_lite_base_mock_py312.sh && echo mock-ok"
  docker exec "$C" bash -lc "bash -n $TOOLS/vllmBench_lite_base_timeline_py312.sh && echo timeline-ok"

  echo "== 2. 新缓存目录状态 =="
  docker exec "$C" bash -lc "ls -d $CACHE 2>/dev/null && echo \"files=\$(find $CACHE -name '*.py' | wc -l)\" || echo 'not created yet'"
  echo "-- 旧目录（/tmp，先保留不动）--"
  docker exec "$C" bash -lc "echo \"/tmp files=\$(find /tmp/torchinductor_root -name '*.py' 2>/dev/null | wc -l)\""

  echo "== 3. 前置检查 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm.entrypoints.openai.api_server|bench_driver" | grep -v pgrep || echo "no server/bench running"'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 free"

  echo "== 4. 启动预热（新缓存目录）=="
  docker exec -d "$C" bash -lc "cd $TOOLS && \
    TEST_ID=$TEST_ID HOST_MEASURE=off MODEL_PATH=$MODEL \
    nohup bash vllmBench_lite_base_mock_py312.sh > $LOG 2>&1"
  sleep 25
  docker exec "$C" bash -lc "grep -E 'inductor_cache=|PREFIX=|全部完成' $LOG 2>/dev/null; tail -3 $LOG 2>/dev/null"

  echo "== 5. 后续 =="
  echo "日志：$LOG（容器内）"
  echo "缓存：$CACHE（容器内）"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
