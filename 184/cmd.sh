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
  # 只读：确认 6.6 兼容分支、dkms.conf、安装器对已安装驱动的处理。
  # 所有 grep 加 -I 跳过二进制，避免把固件字节写进日志。

  X=/tmp/corex-drv-extract

  echo "== 1. kernel_test.sh 中 6.6 的上下文 =="
  grep -I -n -B6 -A10 "6\.6" "$X/kernel/itr/kernel_test.sh" 2>/dev/null | head -40

  echo "== 2. dkms.conf 全文 =="
  cat "$X/kernel/dkms.conf" 2>/dev/null

  echo "== 3. 内核 Makefile 里的版本分支 =="
  grep -I -n "kernel_test\|KERNEL_UNAME\|6\.6\|6\.1\|5\.1\|PAGE_SIZE\|page" \
    "$X/kernel/Makefile" "$X/kernel/itr/Makefile" 2>/dev/null | head -30

  echo "== 4. 安装器对“已安装/卸载”的处理 =="
  grep -I -n "already\|installed\|uninstall\|existing\|uname -r\|kernel-source" \
    "$X/corex-driver-installer" 2>/dev/null | head -30

  echo "== 5. 现有 DKMS 源与安装目录 =="
  ls -la /var/lib/dkms/corex/5.0.0 2>/dev/null | head -10
  ls /var/lib/dkms/corex/5.0.0/build 2>/dev/null | head -10
  ls -ld /usr/src/corex* 2>/dev/null | head -5
  echo "-- corex 用户态版本 --"
  cat /usr/local/corex-5.0.0/bin/corex-driver-uninstaller 2>/dev/null | head -5 || echo "(uninstaller 是二进制)"
  strings /usr/local/corex-5.0.0/bin/corex-driver-uninstaller 2>/dev/null | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
