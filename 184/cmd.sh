#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：确认 /home/lw 的 64k 内核树能否用于编模块。
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
  echo "== /home/lw/20261104-64k =="
  ls -la /home/lw/20261104-64k 2>&1 | head -20

  echo "== /home/lw/kernel =="
  ls -la /home/lw/kernel 2>&1 | head -25
  sed -n '1,6p' /home/lw/kernel/Makefile 2>&1

  echo "== prepared build tree? =="
  ls -l /home/lw/kernel/Module.symvers /home/lw/kernel/.config /home/lw/kernel/vmlinux 2>&1
  grep -E 'CONFIG_ARM64_64K_PAGES|CONFIG_LOCALVERSION' /home/lw/kernel/.config 2>&1
  ls -l /home/lw/kernel/include/generated/asm-offsets.h 2>&1

  echo "== kernelrelease from tree =="
  grep -rn 'CONFIG_LOCALVERSION=' /home/lw/kernel/.config 2>&1
  ls -la /home/lw/20261104-64k/*.rpm 2>&1 | head -5
  find /home/lw -maxdepth 3 -name 'kernel-devel*.rpm' 2>/dev/null | head -5

  echo "== driver kernel dirs available =="
  ls -1 /home/lw/kernel/arch/arm64/boot 2>&1 | head -5

  echo "== dkms.conf in tree? =="
  ls -l /home/lw/kernel/.config /home/lw/kernel/Module.symvers 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
