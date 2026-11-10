#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：确认重启+新内核后容器内 GPU 栈正常。
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
  echo "== container =="
  docker ps --format '{{.Names}}\t{{.Status}}' 2>&1 | head -5

  echo "== devices in container =="
  docker exec corex5-py311 bash -c 'ls -l /dev/iluvatar* 2>&1 | head -6' 2>&1

  echo "== ixsmi in container =="
  docker exec corex5-py311 ixsmi 2>&1 | sed -n '1,16p'

  echo "== venv imports =="
  for V in /opt/corex311 /opt/corex311-cpython-vllm; do
    docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME "$V/bin/python3" -c \
      "import torch,vllm;print('$V ok',torch.__version__,vllm.__version__)" 2>&1 | tail -2
  done

  echo "== r10 still in place =="
  docker exec corex5-py311 bash -c 'ls /opt/corex311/lib/python3.11/site-packages/vllm/v1/worker/host_opt.py /opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm/v1/worker/host_opt.py 2>&1' 2>&1

  echo "== dkms autostart =="
  systemctl is-enabled dkms 2>&1
  systemctl is-active dkms 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
