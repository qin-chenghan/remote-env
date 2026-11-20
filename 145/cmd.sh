#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。对比 vllm 与 mock 两个容器的 Env / LD_LIBRARY_PATH / corex 库，定位 torch 找不到 libcudart。
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

  echo "== 1. 两个容器的镜像与 Env =="
  for c in vllm corex5-py311-mock; do
    echo "-- $c"
    docker inspect "$c" --format 'image={{.Config.Image}}'
    docker inspect "$c" --format '{{json .Config.Env}}' | tr ',' '\n' | grep -E "LD_LIBRARY_PATH|PATH=|PYTHON" | head -6
  done

  echo "== 2. 容器运行时的 LD_LIBRARY_PATH =="
  for c in vllm corex5-py311-mock; do
    echo "-- $c"
    docker exec "$c" bash -lc 'echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<empty>}"'
  done

  echo "== 3. corex 用户态库是否存在 =="
  for c in vllm corex5-py311-mock; do
    echo "-- $c"
    docker exec "$c" bash -lc '
      ls -d /usr/local/corex-5.0.0 /usr/local/corex 2>/dev/null
      ls -l /usr/local/corex/lib64/libcudart.so* /usr/local/corex/lib64/libcublas.so* 2>/dev/null | head -4
      ldd /opt/corex311/lib/python3.11/site-packages/torch/lib/libtorch_cuda.so 2>/dev/null | grep -E "cudart|cublas|not found" | head -4
    ' 2>&1 | head -8
  done

  echo "== 4. 镜像自带 Env（vllm:latest 是否和 corex5-py311 不同）=="
  docker image inspect vllm:latest --format '{{json .Config.Env}}' | tr ',' '\n' | grep -E "LD_LIBRARY|PATH=" | head -6

  echo "== 5. 测试人员那次失败的完整命令 =="
  cat /home/qch/tools/remote-env/145/tmp/litehost_gap_20261120_093438/server.process.json 2>/dev/null
  cat /home/qch/tools/remote-env/145/tmp/litehost_gap_20261120_093438/config.txt 2>/dev/null

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
