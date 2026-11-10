#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读；本脚本在宿主机执行，/opt 属于容器，走 docker exec。
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
  echo "== build flags (all vars) =="
  docker exec corex5-py311 /opt/corex311-cpython-vllm/bin/python3 -c \
    "import sysconfig
for k in ('CFLAGS','PY_CFLAGS','PY_CFLAGS_NODIST','LDFLAGS','PY_LDFLAGS','CONFIGURE_CFLAGS','OPT'):
    print(k,'=',sysconfig.get_config_var(k))" 2>&1

  echo "== build Makefile flags =="
  docker exec corex5-py311 bash -c '
    M=$(ls /opt/cpython-vllm/v1/lib/python3.11/config-*/Makefile 2>/dev/null | head -1)
    echo "makefile=$M"
    [ -n "$M" ] && grep -nE "^CFLAGS=|^PY_CFLAGS=|^LDFLAGS=|^PY_LDFLAGS=|fprofile-use|fprofile-generate|flto" "$M" | head -12
    echo "-- .gcda/.gcno --"
    find /opt/cpython-vllm/v1 -name "*.gcda" -o -name "*.gcno" 2>/dev/null | head -3' 2>&1

  echo "== link-test the native .so =="
  for V in /opt/corex311 /opt/corex311-cpython-vllm; do
    docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME "$V/bin/python3" -c \
      "import importlib
for n in ('vllm._host_opt_native','vllm._host_opt_meta_native'):
    try:
        m=importlib.import_module(n); print(n,'OK',getattr(m,'__file__',''))
    except Exception as e: print(n,'FAIL',type(e).__name__,e)" 2>&1 | sed "s|^|$V: |"
  done

  echo "== host fastpath wiring =="
  for V in /opt/corex311 /opt/corex311-cpython-vllm; do
    echo "-- $V"
    docker exec corex5-py311 bash -c "grep -rln 'VLLM_HOST_FASTPATH\|host_fastpath' $V/lib/python3.11/site-packages/vllm/ 2>/dev/null | head -8" | sed "s|$V/lib/python3.11/site-packages|...|"
  done

  echo "== transformers history hint =="
  docker exec corex5-py311 bash -c '
    for V in /opt/corex311 /opt/corex311-cpython-vllm; do
      d=$V/lib/python3.11/site-packages/transformers-*.dist-info
      echo "$V: $(basename "$d" 2>/dev/null)"
    done' 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
