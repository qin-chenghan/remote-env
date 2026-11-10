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
  echo "== host os =="
  head -2 /etc/os-release
  uname -r
  uptime

  echo "== docker state =="
  docker ps --format '{{.Names}}\t{{.Status}}' 2>&1 | head -5
  docker inspect -f 'name={{.Name}} started={{.State.StartedAt}} image={{.Config.Image}} restarts={{.RestartCount}}' corex5-py311 2>&1

  echo "== failed run =="
  ls -ld /home/s00806700/vllmBench/litehost_gap_20261110_093301 2>&1
  sed -n '1,12p' /home/s00806700/vllmBench/litehost_gap_20261110_093301/logs/server.log 2>&1

  echo "== tcmalloc =="
  ls -l /home/huawei_ts_program/gperftools/.libs/libtcmalloc.so 2>&1
  ls -ld /home/huawei_ts_program/gperftools 2>&1
  find /home/huawei_ts_program -maxdepth 4 -name 'libtcmalloc.so*' 2>/dev/null | head -5

  echo "== container env =="
  docker exec corex5-py311 env 2>&1 | grep -E '^(PYTHON|LD_|VIRTUAL_ENV|PATH=)' | sort

  echo "== PYTHONPATH sources =="
  docker exec corex5-py311 grep -rn 'PYTHONPATH' /etc/profile /etc/profile.d /etc/environment /etc/bashrc /root/.bashrc /opt/use-corex311.sh 2>/dev/null | head -20

  echo "== use-corex311.sh =="
  docker exec corex5-py311 cat /opt/use-corex311.sh 2>&1 | head -40

  echo "== interpreter identity =="
  docker exec corex5-py311 readlink -f /opt/corex311/bin/python3 2>&1
  docker exec corex5-py311 readlink -f /opt/corex311-cpython-vllm/bin/python3 2>&1
  docker exec corex5-py311 /opt/corex311/bin/python3 -c "import sys,sysconfig;print('base exe',sys.executable);print('ver',sys.version.split()[0]);print('base_prefix',sys.base_prefix);print('cfg',sysconfig.get_config_var('CONFIG_ARGS'))" 2>&1
  docker exec corex5-py311 /opt/corex311-cpython-vllm/bin/python3 -c "import sys,sysconfig;print('pgo exe',sys.executable);print('ver',sys.version.split()[0]);print('base_prefix',sys.base_prefix);print('cfg',sysconfig.get_config_var('CONFIG_ARGS'))" 2>&1

  echo "== venv cfg =="
  docker exec corex5-py311 cat /opt/corex311/pyvenv.cfg 2>&1
  docker exec corex5-py311 cat /opt/corex311-cpython-vllm/pyvenv.cfg 2>&1

  echo "== pth files =="
  docker exec corex5-py311 bash -c 'for f in /opt/corex311/lib/python3.11/site-packages/*.pth /opt/corex311-cpython-vllm/lib/python3.11/site-packages/*.pth; do [ -f "$f" ] && { echo "--- $f"; cat "$f"; }; done' 2>&1 | head -40
  docker exec corex5-py311 grep -l 'python3.12' /opt/corex311/lib/python3.11/site-packages/*.pth /opt/corex311-cpython-vllm/lib/python3.11/site-packages/*.pth 2>/dev/null

  echo "== sys.path order =="
  docker exec corex5-py311 /opt/corex311-cpython-vllm/bin/python3 -c "import sys;[print(p) for p in sys.path]" 2>&1

  echo "== torch import, polluted env =="
  docker exec corex5-py311 /opt/corex311/bin/python3 -c "import torch;print('base torch',torch.__version__,torch.__file__)" 2>&1 | tail -5
  docker exec corex5-py311 /opt/corex311-cpython-vllm/bin/python3 -c "import torch;print('pgo torch',torch.__version__,torch.__file__)" 2>&1 | tail -5

  echo "== torch import, clean env =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV -u LD_PRELOAD /opt/corex311/bin/python3 -c "import torch;print('base clean torch',torch.__version__,torch.__file__)" 2>&1 | tail -5
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV -u LD_PRELOAD /opt/corex311-cpython-vllm/bin/python3 -c "import torch;print('pgo clean torch',torch.__version__,torch.__file__)" 2>&1 | tail -5

  echo "== 3.12 tree =="
  docker exec corex5-py311 ls -ld /usr/local/lib/python3.12/site-packages/torch 2>&1
  docker exec corex5-py311 ls /usr/local/lib/python3.12/site-packages/torch/_C 2>&1 | head -5
  docker exec corex5-py311 ls -l /usr/local/lib/python3.12/site-packages/torch/_C*.so 2>&1 | head -3
  docker exec corex5-py311 /usr/local/bin/python3 -V 2>&1
  docker exec corex5-py311 python3 -V 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
