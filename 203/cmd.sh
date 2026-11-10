#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
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
  echo "== 1. 容器内 ixsmi（全路径）=="
  docker exec corex5-py311 bash -lc '
    ls -l /usr/local/corex/bin/ixsmi /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | head -4
    /usr/local/corex/bin/ixsmi 2>&1 | head -20
  ' 2>&1 | head -30

  echo "== 2. 容器内 torch 识别 GPU =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 \
    /opt/corex311/bin/python -c '
import torch
print("torch", torch.__version__)
print("device_count", torch.cuda.device_count())
for i in range(torch.cuda.device_count()):
    print(i, torch.cuda.get_device_name(i))
a = torch.randn(64, 64, device="cuda")
print("matmul ok", float((a @ a).sum()))
' 2>&1 | tail -12

  echo "== 3. 容器 shm =="
  docker exec corex5-py311 bash -lc 'df -h /dev/shm 2>&1 | tail -1; cat /proc/meminfo | head -2' 2>&1

  echo "== 4. 容器内 PATH 与 corex 环境 =="
  docker exec corex5-py311 bash -lc 'echo "PATH=$PATH"; echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<empty>}"' 2>&1 | head -5

  echo "== 5. 多流参数 =="
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
