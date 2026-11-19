#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：清理 145 上的镜像搬运产物（tar + zst）。镜像已在 docker 中，删前先校验。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TAR=/home/qch/transfer/corex5-py311-py3116-20261029.tar
ZST=/home/qch/transfer/corex5-py311-py3116-20261029.tar.zst
IMAGE=corex5-py311:py3116-20261029

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 清理前确认镜像仍在 docker 中 =="
  docker image inspect "$IMAGE" --format '{{.Id}}' || { echo "!! 镜像不存在，拒绝删除文件"; exit 3; }
  docker ps --filter name=corex5-py311-mock --format '{{.Names}} {{.Status}}'

  echo "== 2. 删除前空间 =="
  ls -lh "$TAR" "$ZST" 2>/dev/null
  df -h /home | tail -1

  echo "== 3. 删除 =="
  rm -f "$TAR" "$ZST"
  ls -lh "$TAR" "$ZST" 2>/dev/null || echo "已删除"

  echo "== 4. 删除后空间 =="
  df -h /home | tail -1
  echo "-- transfer 目录剩余 --"
  ls -lh /home/qch/transfer 2>/dev/null | head -10

  echo "== 5. 镜像与容器仍可用 =="
  docker images | grep -E "corex5-py311|REPOSITORY" | head -3
  docker exec corex5-py311-mock bash -lc \
    'PYTHONPATH=/home/qch/mock_vllm /opt/corex311/bin/python3 -c "import mock_gpu.autoload"' 2>&1 | tail -3

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
