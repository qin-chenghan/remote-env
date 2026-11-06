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

  echo "== gpu numa =="
  for b in 0000:45:00.0 0000:48:00.0 0000:af:00.0 0000:b2:00.0; do
    printf '%s numa_node=%s\n' "$b" "$(cat "/sys/bus/pci/devices/$b/numa_node" 2>/dev/null || echo n/a)"
  done
  command -v ixsmi >/dev/null && ixsmi topo -m 2>&1 | head -30

  echo "== vllm processes =="
  ps -eo pid,ppid,args 2>/dev/null | grep -iE 'vllm' | grep -v grep | cut -c1-300 | head -8

  echo "== containers =="
  for r in docker podman nerdctl; do
    command -v "$r" >/dev/null || continue
    echo "runtime: $r"
    "$r" ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1 | head -10
  done

  echo "== inside container =="
  RT=""
  C=""
  for r in docker podman nerdctl; do
    command -v "$r" >/dev/null || continue
    [ -z "$RT" ] && RT="$r"
    [ -z "$C" ] && C=$("$r" ps --format '{{.Names}}' 2>/dev/null | grep -iE 'corex|311' | head -1)
  done
  echo "runtime: ${RT:-<none>}  container: ${C:-<not found>}"
  if [ -n "$RT" ] && [ -n "$C" ]; then
    "$RT" exec "$C" bash -lc '
      echo "python311: $(/opt/corex311/bin/python -V 2>&1)"
      echo "cpython-vllm: $(/opt/corex311-cpython-vllm/bin/python -V 2>&1)"
      /opt/corex311-cpython-vllm/bin/pip list 2>/dev/null | grep -iE "^(vllm|torch|ixsys|triton|transformers)"
      echo "LD_PRELOAD=${LD_PRELOAD:-<empty>}"
      ls /opt 2>/dev/null
    ' 2>&1 | head -40
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
