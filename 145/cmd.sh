#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：部署天数 mock 环境（解压镜像 → docker load → 起容器 → 冒烟）。
# 前置：把 corex5-py311-py3116-20261029.tar.zst 放到 /home/qch/transfer/。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  IMG=/home/qch/transfer/corex5-py311-py3116-20261029.tar.zst
  TAR=/home/qch/transfer/corex5-py311-py3116-20261029.tar
  EXPECT=d76cd175
  EXPECT_ZST=dc479721103811984b4f08a397da6f78825a5457a8773f35995b44a80e29f5ff

  echo "== 1. 文件与空间 =="
  ls -lh "$IMG" 2>/dev/null || { echo "!! 缺 $IMG，先拷文件"; exit 3; }
  sha256sum "$IMG"
  echo "期望 sha256=$EXPECT_ZST"
  df -h /home | tail -1

  echo "== 2. 解压 =="
  if [ -f "$TAR" ]; then
    echo "已存在 $TAR，跳过"
  else
    if command -v zstd >/dev/null 2>&1; then
      zstd -d "$IMG" -o "$TAR" || exit 1
    else
      echo "宿主无 zstd，用镜像解压"
      docker run --rm --security-opt label=disable -v /home:/home zstd:latest \
        zstd -d "$IMG" -o "$TAR" || exit 1
    fi
  fi
  ls -lh "$TAR"

  echo "== 3. docker load =="
  docker load -i "$TAR" || exit 1
  docker images | grep -E "corex5-py311|REPOSITORY" | head -5

  echo "== 4. 起 mock 容器（无特权、无设备、label=disable）=="
  docker rm -f corex5-py311-mock 2>/dev/null
  docker run -d --name corex5-py311-mock --network host \
    --security-opt label=disable -v /home:/home \
    corex5-py311:py3116-20261029 sleep infinity || exit 1
  sleep 3
  docker ps --filter name=corex5-py311-mock --format '{{.Names}} {{.Status}}'

  echo "== 5. 容器内环境自检 =="
  docker exec corex5-py311-mock bash -lc '
    uname -m
    /opt/corex311/bin/python3 -V
    ls -l /usr/local/corex/lib64/libcuda.so.1
    /opt/corex311/bin/python3 -c "import torch; print(torch.__version__)"
    ls -d /dev/iluvatar* 2>/dev/null || echo "no device (expected)"
  ' 2>&1 | tail -12

  echo "== 6. mock 激活冒烟（需要 /home/qch/mock_vllm 已就位）=="
  docker exec corex5-py311-mock bash -lc '
    if [ -d /home/qch/mock_vllm/mock_gpu ]; then
      PYTHONPATH=/home/qch/mock_vllm /opt/corex311/bin/python3 -c "import mock_gpu.autoload" 2>&1 | tail -3
    else
      echo "缺 /home/qch/mock_vllm/mock_gpu：cd remote-env 后拷过去"
    fi
  ' 2>&1 | tail -6

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
