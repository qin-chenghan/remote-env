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
  H=/home/huawei_ts_program/litehost_perf_opt
  TC=/home/lw/gperftools/.libs/libtcmalloc.so

  echo "== gpu free? =="
  ixsmi 2>&1 | sed -n '5,25p'

  echo "== smoke: base venv, patched env =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME \
    PYTHONPATH="$H" LD_PRELOAD="$H/liblitehost.so:$TC" \
    /opt/corex311/bin/python3 -c \
    "import torch,vllm;print('base',torch.__version__,vllm.__version__,torch.__file__)" 2>&1 | tail -4

  echo "== smoke: pgo venv, patched env =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME \
    PYTHONPATH="$H" LD_PRELOAD="$H/liblitehost.so:$TC" \
    /opt/corex311-cpython-vllm/bin/python3 -c \
    "import torch,vllm;print('pgo',torch.__version__,vllm.__version__,torch.__file__)" 2>&1 | tail -4

  echo "== smoke: worker cls importable =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME PYTHONPATH="$H" \
    /opt/corex311-cpython-vllm/bin/python3 -c \
    "import light_host_worker;print('worker ok',light_host_worker.LightHostWorker)" 2>&1 | tail -4

  echo "== effective launch env =="
  grep -n 'CLEAN_ENV=(env\|env_args+=(PYTHONPATH\|LD_PRELOAD=' "$H"/vllmBench_lite_opt.sh 2>&1 | head -6

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
