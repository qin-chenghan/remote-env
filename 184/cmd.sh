#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：查默认内核、可用内核、重启历史，以及 64K 内核是否还在。
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
  echo "== current =="
  uname -r
  getconf PAGE_SIZE
  uptime

  echo "== grub default =="
  grubby --default-kernel 2>&1
  grub2-editenv list 2>&1
  grep -nE '^GRUB_DEFAULT|^GRUB_ENABLE_BLSCFG' /etc/default/grub 2>&1

  echo "== boot entries =="
  grubby --info=ALL 2>&1 | grep -E '^(index|kernel|title)=' | head -24

  echo "== kernels on disk =="
  ls -l /boot/vmlinuz-* /boot/config-* 2>&1 | head -20
  ls -1 /lib/modules/ 2>&1

  echo "== installed kernel packages =="
  rpm -qa 'kernel-6.6*' 'kernel-64k*' 2>&1 | sort | head -12

  echo "== dkms per kernel =="
  dkms status 2>&1 | head -10

  echo "== 64K kernel leftovers =="
  find /boot /lib/modules -maxdepth 2 -iname '*64K*' 2>/dev/null | head -10

  echo "== reboot history =="
  last -x reboot 2>&1 | head -8
  echo "-- shutdown --"
  last -x shutdown 2>&1 | head -5

  echo "== crash/oops in previous boot =="
  journalctl -b -1 -p err --no-pager 2>/dev/null | tail -8

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
