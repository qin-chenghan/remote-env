#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：评估"自行重建内核产生 Module.symvers"是否可行。
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
  echo "== module signing policy =="
  grep -E '^CONFIG_MODULE_SIG_FORCE|^CONFIG_MODULE_COMPRESS' /boot/config-6.6.02403_sp3-64K 2>&1
  echo "modules_disabled=$(cat /proc/sys/kernel/modules_disabled 2>&1)"

  echo "== existing iluvatar module on 145 (for comparison) =="
  modinfo -F vermagic /lib/modules/6.6.0-145.3.37.168.oe2403sp3.aarch64/updates/iluvatar.ko.xz 2>&1
  modinfo -F sig_id /lib/modules/6.6.0-145.3.37.168.oe2403sp3.aarch64/updates/iluvatar.ko.xz 2>&1

  echo "== local kernel source trees =="
  rpm -qa 'kernel-source*' 2>&1
  ls -d /usr/src/linux-* 2>&1
  S=/usr/src/linux-6.6.0-145.3.37.168.oe2403sp3.aarch64
  sed -n '1,6p' "$S/Makefile" 2>&1
  echo "-- patches applied? --"
  ls "$S" 2>&1 | head -20

  echo "== disk space =="
  df -h / /home /usr/src 2>&1 | tail -4

  echo "== gcc version =="
  gcc --version 2>&1 | head -2

  echo "== any oe kernel src rpm on disk =="
  find /home /root -maxdepth 4 -iname 'kernel-*src.rpm' 2>/dev/null | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
