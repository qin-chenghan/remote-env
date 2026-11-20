#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：把宿主上已改好的 py312 脚本同步进 vllm 容器（两份 /home 是独立的）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TOOLS=/home/huawei_ts_program/litehost_perf_opt
C=vllm
FILES="vllmBench_lite_base_mock_py312.sh vllmBench_lite_base_timeline_py312.sh"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 同步前：两边默认值 =="
  echo "-- 宿主"
  grep -n "MODEL_PATH=" "$TOOLS"/vllmBench_lite_base_mock_py312.sh | head -2
  echo "-- 容器"
  docker exec "$C" bash -lc "grep -n 'MODEL_PATH=' $TOOLS/vllmBench_lite_base_mock_py312.sh | head -2"

  echo "== 2. 覆盖进容器 =="
  for f in $FILES; do
    docker cp "$TOOLS/$f" "$C":"$TOOLS/$f" || exit 1
  done
  docker exec "$C" chmod +x "$TOOLS"/vllmBench_lite_base_*_py312.sh

  echo "== 3. 同步后：两边一致性 =="
  for f in $FILES; do
    echo "-- $f"
    sha256sum "$TOOLS/$f" | awk '{print "  host   " $1}'
    docker exec "$C" sha256sum "$TOOLS/$f" | awk '{print "  ctr    " $1}'
  done

  echo "== 4. 容器内实际默认值 =="
  docker exec "$C" bash -lc "grep -n 'MODEL_PATH=' $TOOLS/vllmBench_lite_base_mock_py312.sh $TOOLS/vllmBench_lite_base_timeline_py312.sh | head -4"

  echo "== 5. 默认值指向的目录是否存在 =="
  docker exec "$C" bash -lc '
    def=$(sed -n "s/.*MODEL_PATH=\"\${MODEL_PATH:-\([^}]*\)}\".*/\1/p" '"$TOOLS"'/vllmBench_lite_base_mock_py312.sh | head -1)
    echo "default=$def"
    [ -d "$def" ] && echo "default dir OK" || echo "!! default dir MISSING"
  '

  echo "== 6. 语法 =="
  docker exec "$C" bash -lc "bash -n $TOOLS/vllmBench_lite_base_mock_py312.sh && echo mock-ok"
  docker exec "$C" bash -lc "bash -n $TOOLS/vllmBench_lite_base_timeline_py312.sh && echo timeline-ok"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
