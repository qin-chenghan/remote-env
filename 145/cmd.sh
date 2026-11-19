#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：给 mock 容器加 CAP_SYS_NICE（numactl 的 get/set_mempolicy 需要），重建容器并验证。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

CONTAINER=corex5-py311-mock
IMAGE=corex5-py311:py3116-20261029

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 重建前状态 =="
  docker inspect "$CONTAINER" --format 'CapAdd={{.HostConfig.CapAdd}} SecurityOpt={{.HostConfig.SecurityOpt}}' 2>/dev/null
  docker exec "$CONTAINER" bash -lc 'numactl --show 2>&1 | head -2' 2>/dev/null
  ss -ltn 2>/dev/null | grep ':8948 ' && { echo "!! 8948 被占用，先确认没有在跑的服务"; exit 5; }

  echo "== 2. 重建容器（参数与之前一致，仅加 cap）=="
  docker rm -f "$CONTAINER"
  docker run -d --name "$CONTAINER" --network host \
    --security-opt label=disable --cap-add SYS_NICE \
    -v /home:/home "$IMAGE" sleep infinity || exit 1
  sleep 3
  docker ps --filter "name=$CONTAINER" --format '{{.Names}} {{.Status}}'

  echo "== 3. numactl 验证 =="
  docker exec "$CONTAINER" bash -lc 'numactl --show' | head -7
  docker exec "$CONTAINER" bash -lc \
    'numactl --cpunodebind=0 --membind=0 numactl --show' | head -5

  echo "== 4. mock 仍正常激活 =="
  docker exec "$CONTAINER" bash -lc \
    'PYTHONPATH=/home/qch/mock_vllm /opt/corex311/bin/python3 -c "import mock_gpu.autoload"' 2>&1 | tail -3

  echo "== 5. 设备仍不可见（应保持无 /dev/iluvatar）=="
  docker exec "$CONTAINER" bash -lc 'ls /dev/iluvatar* 2>/dev/null || echo "no device (expected)"'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
