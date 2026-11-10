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

  echo "== os =="
  uname -a
  head -3 /etc/os-release 2>/dev/null

  echo "== container =="
  cat /proc/1/cgroup 2>/dev/null | head -5
  ls -d /opt/* 2>/dev/null

  echo "== python/venv =="
  for p in /opt/corex311/bin/python /opt/corex311-cpython-vllm/bin/python; do
    [ -x "$p" ] && echo "$p -> $("$p" -V 2>&1)"
  done

  echo "== gpu tools =="
  for c in ixsmi ix-smi mx-smi mxsmi nvidia-smi; do
    command -v "$c" >/dev/null && { echo "found: $c"; "$c" 2>&1 | head -40; }
  done

  echo "== gpu pci numa =="
  for d in /sys/bus/pci/devices/*; do
    cls=$(cat "$d/class" 2>/dev/null) || continue
    case "$cls" in
      0x0300*|0x0302*)
        printf '%s vendor=%s numa_node=%s\n' \
          "$(basename "$d")" \
          "$(cat "$d/vendor" 2>/dev/null)" \
          "$(cat "$d/numa_node" 2>/dev/null || echo n/a)"
        ;;
    esac
  done

  echo "== topo =="
  command -v ixsmi >/dev/null && ixsmi topo -m 2>&1 | head -30

  echo "== cpu/numa =="
  lscpu 2>/dev/null | head -28
  command -v numactl >/dev/null && numactl -H 2>&1 | head -25

  echo "== mem/disk =="
  free -g 2>/dev/null
  df -h / /home 2>/dev/null

  echo "== env =="
  echo "LD_PRELOAD=${LD_PRELOAD:-<empty>}"
  echo "VIRTUAL_ENV=${VIRTUAL_ENV:-<empty>}"
  echo "PATH=$(echo "$PATH" | tr ':' '\n' | head -15)"

  echo "== containers =="
  for r in docker podman nerdctl; do
    command -v "$r" >/dev/null || continue
    echo "runtime: $r"
    "$r" ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1 | head -10
  done

  echo "== repo =="
  git -C "$DIR/.." log --oneline -3 2>&1
  git -C "$DIR/.." status --short 2>&1 | head

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
