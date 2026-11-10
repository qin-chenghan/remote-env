#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：为 6.6.02403_sp3-64K 找 kernel-devel / 源码。
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
  K=6.6.02403_sp3-64K

  echo "== repos =="
  dnf repolist 2>&1 | head -25

  echo "== available kernel devel (skip broken repo) =="
  dnf --disablerepo='OpenStack_Wallaby' --disablerepo='OpenStack_Wallaby*' \
      list --available 'kernel-devel*' 'kernel*64K*' 'kernel*64kb*' 2>&1 | tail -20

  echo "== search 6.6.02403 =="
  dnf --disablerepo='OpenStack_Wallaby' --disablerepo='OpenStack_Wallaby*' \
      search '6.6.02403' 2>&1 | head -20

  echo "== local rpm files =="
  find /home /root /opt /tmp /var/tmp -maxdepth 4 -iname 'kernel*.rpm' 2>/dev/null | head -10
  ls -l /boot | grep -iE '64K|02403' 2>&1 | head -10

  echo "== build target exists? =="
  ls -la /usr/lib/modules/$K 2>&1 | head -10
  ls -l /usr/lib/modules/$K/build 2>&1
  ls -l /boot/config-$K /boot/System.map-$K 2>&1 | head -4

  echo "== source trees =="
  ls -d /usr/src/* 2>&1 | head -10
  find /usr/src /opt /home -maxdepth 3 -type f -name 'Makefile' -path '*linux*' 2>/dev/null | head -5

  echo "== kernel meta =="
  uname -v
  grep -E 'CONFIG_ARM64_64K_PAGES|CONFIG_LOCALVERSION' /boot/config-$K 2>/dev/null
  ls -l /boot/vmlinuz-$K 2>&1

  echo "== rpmdb health =="
  rpm -qa 2>/dev/null | wc -l
  rpm -q "kernel-6.6.02403_sp3_64K" 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
