#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：64K 内核重启后的环境体检（跑 timeline 前）。
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
  echo "== kernel =="
  uname -r; uname -v
  getconf PAGE_SIZE
  cat /proc/config.gz 2>/dev/null | zcat 2>/dev/null | grep -E '^CONFIG_ARM64_64K_PAGES' || grep -E '^CONFIG_ARM64_64K_PAGES' /boot/config-$(uname -r) 2>/dev/null

  echo "== container =="
  docker ps --format '{{.Names}}\t{{.Status}}' 2>&1 | head -3
  docker exec corex5-py311 bash -c 'ls -l /dev/iluvatar* 2>&1 | head -5' 2>&1

  echo "== gpu in container =="
  docker exec corex5-py311 ixsmi 2>&1 | sed -n '5,20p'

  echo "== venv imports =="
  for V in /opt/corex311 /opt/corex311-cpython-vllm; do
    docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME "$V/bin/python3" -c \
      "import torch,vllm;print('$V',torch.__version__,vllm.__version__)" 2>&1 | tail -2
  done

  echo "== PYTHONPATH in container =="
  docker exec corex5-py311 bash -c 'echo "PYTHONPATH=${PYTHONPATH:-<unset>}"' 2>&1

  echo "== r10 artifacts =="
  docker exec corex5-py311 bash -c 'ls /opt/corex311/lib/python3.11/site-packages/vllm/v1/worker/host_opt.py /opt/corex311/lib/python3.11/site-packages/vllm/_host_opt_meta_native*.so 2>&1' 2>&1

  echo "== tcmalloc preload =="
  docker exec corex5-py311 env LD_PRELOAD=/home/lw/gperftools/.libs/libtcmalloc.so /bin/true; echo "preload rc=$?"

  echo "== free mem =="
  free -g 2>&1 | head -3

  echo "== multi engine =="
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>&1

  echo "== timeline dirs =="
  ls -lt /home/qch/scripts/timeline/ 2>&1 | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
