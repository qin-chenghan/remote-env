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

  echo "== lspci accelerators =="
  lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display|accelerator|iluvatar|metax|nvidia|co-processor' | head -30

  echo "== gpu pci -> vendor/numa =="
  for d in /sys/bus/pci/devices/*; do
    cls=$(cat "$d/class" 2>/dev/null) || continue
    case "$cls" in
      0x030000|0x030200|0x120000|0x120100)
        printf '%s class=%s vendor=%s device=%s numa=%s\n' \
          "$(basename "$d")" "$cls" \
          "$(cat "$d/vendor" 2>/dev/null)" \
          "$(cat "$d/device" 2>/dev/null)" \
          "$(cat "$d/numa_node" 2>/dev/null || echo n/a)"
        ;;
    esac
  done

  echo "== driver modules =="
  lsmod 2>/dev/null | grep -Ei 'iluvatar|ix|metax|mx|nvidia|corex' | head -20
  for m in /sys/module/*; do
    case "$(basename "$m")" in
      *iluvatar*|*metax*|*mx*|*nvidia*) echo "module: $(basename "$m")";;
    esac
  done

  echo "== corex dirs =="
  ls -d /usr/local/corex* /usr/local/openmpi 2>/dev/null
  cat /usr/local/corex/version 2>/dev/null || ls /usr/local/corex 2>/dev/null | head

  echo "== main container corex5-py311 =="
  docker exec corex5-py311 bash -lc '
    echo "--- ixsmi -L ---"; ixsmi -L 2>&1 | head -10
    echo "--- devices ---"; ls /dev | grep -Ei "iluvatar|ix|metax|mx|nvidia|dri" | head -20
    echo "--- /opt ---"; ls /opt
    echo "--- venv ---"
    for p in /opt/corex311/bin/python /opt/corex311-cpython-vllm/bin/python; do
      [ -x "$p" ] && echo "$p -> $("$p" -V 2>&1)"
    done
    echo "--- packages ---"
    /opt/corex311/bin/pip list 2>/dev/null | grep -iE "^(vllm|torch|ixsys|triton|transformers)"
    echo "--- env ---"
    echo "LD_PRELOAD=${LD_PRELOAD:-<empty>}"
    echo "COREX_VERSION=${COREX_VERSION:-<empty>}"
  ' 2>&1 | head -60

  echo "== container device/job spec =="
  docker inspect corex5-py311 --format '{{json .HostConfig.DeviceRequests}}' 2>&1 | head -5
  docker inspect corex5-py311 --format '{{range .HostConfig.Binds}}{{.}}{{"\n"}}{{end}}' 2>&1 | head -10

  echo "== running gpu processes =="
  ps -eo pid,args 2>/dev/null | grep -Ei 'vllm|ixsmi' | grep -v grep | cut -c1-200 | head -6

  echo "== maca/mx =="
  ls /opt/maca-3.3.0 2>/dev/null | head -10
  command -v mx-smi >/dev/null && mx-smi -L 2>&1 | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
