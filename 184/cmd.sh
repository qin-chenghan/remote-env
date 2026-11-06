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

  echo "== main container corex5-py311 =="
  docker exec corex5-py311 bash -lc '
    echo "python311: $(/opt/corex311/bin/python -V 2>&1)"
    echo "cpython-vllm: $(/opt/corex311-cpython-vllm/bin/python -V 2>&1)"
    echo "-- corex311 --"
    /opt/corex311/bin/pip list 2>/dev/null | grep -iE "^(vllm|torch|ixsys|triton|transformers)"
    echo "-- cpython-vllm --"
    /opt/corex311-cpython-vllm/bin/pip list 2>/dev/null | grep -iE "^(vllm|torch|ixsys|triton|transformers)"
    echo "LD_PRELOAD=${LD_PRELOAD:-<empty>}"
    ls /opt
  ' 2>&1 | head -50

  echo "== vllm full cmdline / env =="
  for p in $(pgrep -f vllm.entrypoints.openai.api_server 2>/dev/null); do
    echo "PID $p:"
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null; echo
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -iE 'corex|itr_|LD_|VLLM' | head -15
    echo
  done

  echo "== bench script =="
  P=$(pgrep -f vllmBench_lite_opt.sh 2>/dev/null | head -1)
  if [ -n "$P" ]; then
    D=$(readlink "/proc/$P/cwd" 2>/dev/null)
    echo "cwd: $D"
    tr '\0' ' ' < "/proc/$P/cmdline"; echo
    sed -n '1,120p' "$D/vllmBench_lite_opt.sh" 2>&1
  else
    echo "not running"
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
