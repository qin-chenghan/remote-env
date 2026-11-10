#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：确认当前 64K 内核能否编译驱动，以及能否回退到有驱动的内核。
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
  K=$(uname -r)

  echo "== current kernel provenance =="
  cat /proc/cmdline
  ls -la "/lib/modules/$K" 2>&1 | head -12
  readlink -f "/lib/modules/$K/build" 2>&1
  readlink -f "/lib/modules/$K/source" 2>&1
  rpm -qf "/lib/modules/$K" 2>&1
  rpm -qa | grep -iE '^kernel-(64k|core|devel|modules)' | sort | head -20

  echo "== boot entries =="
  grubby --default-kernel 2>&1
  grubby --info=ALL 2>&1 | grep -E '^(index|kernel|title)=' | head -30

  echo "== available kernel-devel =="
  dnf list --available 'kernel-devel*' 2>&1 | tail -12
  dnf list --installed 'kernel-devel*' 2>&1 | tail -8

  echo "== source trees =="
  ls -d /usr/src/kernels/* /usr/src/linux-* 2>&1 | head
  ls -l /usr/src/corex-5.0.0 2>&1 | head -8

  echo "== driver dirs for other kernels =="
  ls -l /lib/modules/6.6.0-145.3.37.168.oe2403sp3.aarch64/updates/ 2>&1 | head -8

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
