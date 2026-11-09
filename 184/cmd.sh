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
  # 只读：为 6.6 内核重装 iluvatar 5.0.0 驱动做前置调查。
  # 不执行 .run、不 insmod、不 reboot。

  RUN=/home/qch/transfer/scripts/corex-driver-linux64-5.0.0_aarch64.run

  echo "== 1. 驱动安装器文件 =="
  ls -l "$RUN" 2>/dev/null || echo "missing $RUN"
  sha256sum "$RUN" 2>/dev/null
  file "$RUN" 2>/dev/null
  echo "-- 头部（前 30 行）--"
  head -n 30 "$RUN" 2>/dev/null | strings | head -30
  echo "-- 关键字符串搜索 --"
  grep -a -oE "makeself|MS_ARCHIVE_OFFSET|install|uninstall|kernel|dkms|--help|--silent|accept" "$RUN" 2>/dev/null | sort | uniq -c | head -20

  echo "== 2. 当前内核与 OS =="
  uname -r
  cat /etc/os-release 2>/dev/null | head -8
  getconf PAGESIZE

  echo "== 3. 内核头文件/构建目录 =="
  rpm -qa 2>/dev/null | grep -E "kernel-devel|kernel-headers|kernel-default-devel|kernel-source" | head -10 || echo "rpm 无 kernel-devel"
  ls -d /usr/src/kernels/* 2>/dev/null | head -10
  ls -l "/lib/modules/$(uname -r)/build" "/lib/modules/$(uname -r)/source" 2>&1 | head -5
  ls "/lib/modules/$(uname -r)" 2>/dev/null | head -10

  echo "== 4. 旧内核里的 iluvatar.ko 与旧驱动安装形态 =="
  find /lib/modules -name "iluvatar.ko*" -printf "%p\n" 2>/dev/null | head -10
  ls -d /usr/local/corex* /usr/local/iluvatar* 2>/dev/null
  ls -la /usr/local/corex-5.0.0 2>/dev/null | head -10
  find /usr/local/corex-5.0.0 -maxdepth 3 \( -name "uninstall*" -o -name "*.ko" -o -name "*install*.sh" \) 2>/dev/null | head -10

  echo "== 5. 编译工具 =="
  for c in gcc g++ make dkms ld; do command -v "$c" || echo "no $c"; done
  gcc --version 2>/dev/null | head -1

  echo "== 6. grub 候选（备选：回旧内核） =="
  grubby --default-kernel 2>/dev/null || echo "grubby 不可用"
  grubby --info=ALL 2>/dev/null | grep -E "index=|kernel=" | head -20

  echo "== 7. 模块加载尝试痕迹 =="
  dmesg 2>/dev/null | grep -iE "iluvatar|module verification|version magic" | tail -10 || echo "无"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
