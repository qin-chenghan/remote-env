#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：重启后检查驱动与 64K 内核配套情况。
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
  echo "== kernel =="
  echo "running=$K"
  uname -v
  uptime
  cat /proc/cmdline

  echo "== driver =="
  lsmod | grep -i iluvatar || echo "  not loaded"
  ls -l /dev/iluvatar* 2>&1
  modinfo iluvatar 2>&1 | grep -E 'filename|vermagic' | head -3
  ixsmi 2>&1 | head -14

  echo "== devel tree for this kernel =="
  ls -d "/usr/src/kernels/$K" 2>&1
  ls -l "/usr/src/kernels/$K/Module.symvers" 2>&1
  rpm -qa 'kernel-devel*' 2>&1

  echo "== new rpms =="
  ls -lt /home/l30029702/64k 2>&1 | head -8
  find /home /root -maxdepth 4 -iname 'kernel-devel-6.6.02403*' 2>/dev/null | head -5

  echo "== dkms =="
  dkms status 2>&1 | head -10

  echo "== modules dir =="
  ls -l /lib/modules/$K/updates 2>&1 | head -8

  echo "== dmesg =="
  dmesg 2>/dev/null | grep -iE 'iluvatar|corex' | tail -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
