#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 注意：本脚本在宿主机执行；/opt 属于容器，必须走 docker exec。只读。
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
  echo "== running vllm =="
  ps -eo pid,args 2>/dev/null | grep -E 'vllm.entrypoints|Worker_TP' | grep -v grep | cut -c1-200 | head -6

  echo "== running vllm env (PREFIX-ish) =="
  P=$(pgrep -f 'vllm.entrypoints.openai.api_server' 2>/dev/null | head -1)
  if [ -n "$P" ]; then
    echo "pid=$P cwd=$(readlink /proc/$P/cwd 2>/dev/null)"
    tr '\0' '\n' < "/proc/$P/environ" 2>/dev/null | grep -E 'PYTHONPATH|VIRTUAL_ENV|VLLM_|TORCH_|LIGHTHOST|LD_PRELOAD|UMD_' | sort
    echo "-- argv --"
    tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null | cut -c1-400; echo
  else
    echo "no vllm server process"
  fi

  echo "== interpreter build flags =="
  for V in /opt/corex311 /opt/corex311-cpython-vllm; do
    echo "-- $V"
    docker exec corex5-py311 "$V/bin/python3" -c \
      "import sys,sysconfig
print('ver',sys.version.split()[0],'base',sys.base_prefix)
print('cfg',sysconfig.get_config_var('CONFIG_ARGS'))
print('py_cflags',sysconfig.get_config_var('PY_CFLAGS'))
print('pgo_use','-fprofile-use' in (sysconfig.get_config_var('PY_CFLAGS') or ''))
print('lto','-flto' in (sysconfig.get_config_var('PY_CFLAGS') or ''))" 2>&1
  done

  echo "== vllm patch artifacts =="
  for V in /opt/corex311 /opt/corex311-cpython-vllm; do
    echo "-- $V"
    docker exec corex5-py311 bash -c "ls -l $V/lib/python3.11/site-packages/vllm/_host_opt_native*.so $V/lib/python3.11/site-packages/vllm/_host_opt_meta_native*.so $V/lib/python3.11/site-packages/vllm/v1/worker/host_fastpath.py 2>&1" | sed "s|$V/lib/python3.11/site-packages|...|"
    docker exec corex5-py311 bash -c "grep -l 'DISABLE_DECODE_FASTPATH\|host_fastpath' -r $V/lib/python3.11/site-packages/vllm/v1/worker/*.py 2>/dev/null | head -5" | sed "s|$V/lib/python3.11/site-packages|...|"
  done

  echo "== pgo marker inside venv =="
  docker exec corex5-py311 bash -c 'ls -l /opt/cpython-vllm/v1/bin/python3.11; /opt/cpython-vllm/v1/bin/python3.11 -c "import sysconfig;print(sysconfig.get_config_var(\"CONFIG_ARGS\"))"' 2>&1

  echo "== vllm/torch versions both venvs =="
  for V in /opt/corex311 /opt/corex311-cpython-vllm; do
    docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME "$V/bin/python3" -c \
      "import importlib.metadata as m
for n in ('vllm','torch','triton','transformers','torch-module-attr-fastpath','vllm-corex-metadata'):
    try: print(n, m.version(n))
    except Exception as e: print(n, 'MISSING')" 2>&1 | sed "s|^|$V: |"
  done

  echo "== multi engine =="
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
