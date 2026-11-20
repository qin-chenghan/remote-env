#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：把 py312 版脚本装到宿主和 vllm 容器里，并确认 3.12 依赖齐全。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

SRC="$DIR/../litehost_toolkit"
TOOLS=/home/huawei_ts_program/litehost_perf_opt
C=vllm

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 源文件 =="
  ls -l "$SRC"/vllmBench_lite_base_mock_py312.sh "$SRC"/vllmBench_lite_base_timeline_py312.sh

  echo "== 2. 装到宿主工具目录 =="
  mkdir -p "$TOOLS"
  cp -f "$SRC"/vllmBench_lite_base_mock_py312.sh "$SRC"/vllmBench_lite_base_timeline_py312.sh "$TOOLS"/
  chmod +x "$TOOLS"/vllmBench_lite_base_*_py312.sh
  ls -l "$TOOLS"/vllmBench_lite_base_*_py312.sh

  echo "== 3. 装进 vllm 容器（该容器 /home 不是宿主 /home）=="
  docker cp "$TOOLS"/vllmBench_lite_base_mock_py312.sh "$C":/"$TOOLS"/vllmBench_lite_base_mock_py312.sh
  docker cp "$TOOLS"/vllmBench_lite_base_timeline_py312.sh "$C":/"$TOOLS"/vllmBench_lite_base_timeline_py312.sh
  docker exec "$C" chmod +x "$TOOLS"/vllmBench_lite_base_*_py312.sh
  docker exec "$C" bash -lc "ls -l $TOOLS/vllmBench_lite_base_*_py312.sh; grep -n 'PREFIX=' $TOOLS/vllmBench_lite_base_mock_py312.sh | head -2"

  echo "== 4. 语法与解释器 =="
  docker exec "$C" bash -lc "bash -n $TOOLS/vllmBench_lite_base_mock_py312.sh && echo mock-ok"
  docker exec "$C" bash -lc "bash -n $TOOLS/vllmBench_lite_base_timeline_py312.sh && echo timeline-ok"
  docker exec "$C" bash -lc 'python3 -V; /opt/corex311/bin/python3 -V'

  echo "== 5. 3.12 依赖检查（脚本会用到 aiohttp/requests 等）=="
  docker exec -i "$C" bash -lc 'python3 - <<PY
mods = ("aiohttp", "requests", "numpy", "psutil", "transformers")
for m in mods:
    try:
        __import__(m); print(m, "ok")
    except Exception as e:
        print(m, "MISSING", type(e).__name__)
PY'

  echo "== 6. 用法 =="
  echo "docker exec $C bash -lc 'cd $TOOLS && MODEL_PATH=/home/model/Qwen3-32B-W8A8 HOST_MEASURE=lite bash vllmBench_lite_base_mock_py312.sh'"
  echo "docker exec $C bash -lc 'cd $TOOLS && MODEL_PATH=/home/model/Qwen3-32B-W8A8 bash vllmBench_lite_base_timeline_py312.sh'"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
