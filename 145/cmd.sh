#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：为正式 bench 准备工具链——解包 litehost、编 mock_ix.so、检查容器内依赖与 CPU 绑定。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TGZ=/home/qch/transfer/litehost_tools.tgz
TOOLS=/home/huawei_ts_program/litehost_perf_opt
MOCK=/home/qch/mock_vllm
CONTAINER=corex5-py311-mock

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 解包 litehost 工具 =="
  [ -f "$TGZ" ] || { echo "!! 缺 $TGZ，先从 32 拷 litehost_tools.tgz"; exit 3; }
  mkdir -p "$TOOLS"
  tar xzf "$TGZ" -C "$TOOLS" || exit 1
  ls -lh "$TOOLS"/liblitehost.so "$TOOLS"/vllmBench_lite_base_timeline.sh
  file "$TOOLS"/liblitehost.so | cut -c1-110
  ls "$TOOLS" | wc -l

  echo "== 2. 编 mock_ix.so（litehost 的符号垫片）=="
  [ -d "$MOCK" ] || { echo "!! 缺 $MOCK"; exit 3; }
  gcc -shared -fPIC -o "$MOCK/mock_ix.so" "$MOCK/mock_ix.c" || exit 1
  ls -lh "$MOCK/mock_ix.so"
  file "$MOCK/mock_ix.so" | cut -c1-110

  echo "== 3. 容器内依赖检查 =="
  docker ps --filter "name=$CONTAINER" --format '{{.Names}} {{.Status}}'
  docker exec "$CONTAINER" bash -lc '
    command -v taskset python3 gcc 2>&1
    ls -l /home/huawei_ts_program/litehost_perf_opt/liblitehost.so /home/qch/mock_vllm/mock_ix.so 2>&1
    nproc
  ' 2>&1 | tail -8

  echo "== 4. CPU / NUMA 拓扑（决定 taskset 绑核范围）=="
  lscpu | grep -E "NUMA node\(s\)|NUMA node[0-9]" | head -6
  nproc

  echo "== 5. 端口与余量 =="
  ss -ltn 2>/dev/null | grep ':8948 ' || echo "8948 空闲"
  df -h /home | tail -1
  free -g | head -1

  echo "== 6. harness 参数确认（不改，只打印）=="
  grep -nE "MODEL_PATH|_timeline_cpu_range|_timeline_port|MOCK_DIR" \
    "$TOOLS/vllmBench_lite_base_timeline.sh" | head -8

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
