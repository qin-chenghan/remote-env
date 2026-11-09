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
  # 只读：安全解包 CoreX 5.0.0 驱动安装器（--noexec），看帮助、内核限制、DKMS 配置。
  # 不执行安装、不加载模块、不重启。

  RUN=/home/qch/transfer/scripts/corex-driver-linux64-5.0.0_aarch64.run
  X=/tmp/corex-drv-extract

  echo "== 1. 安装器帮助（makeself --help，不执行安装脚本）=="
  sh "$RUN" --help 2>&1 | head -60

  echo "== 2. 解包（--noexec --keep）=="
  rm -rf "$X"
  sh "$RUN" --noexec --keep --target "$X" 2>&1 | tail -6
  echo "-- 解包内容 --"
  find "$X" -maxdepth 3 | head -50

  echo "== 3. 安装脚本头部 =="
  head -120 "$X/corex-driver-installer" 2>/dev/null || echo "installer script not found"

  echo "== 4. 内核版本/支持相关字符串 =="
  grep -rioE "6\.6|5\.10|supported kernel|kernel version|unsupported kernel|dkms" "$X" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -20

  echo "== 5. DKMS 配置与模块源 =="
  find "$X" -maxdepth 4 \( -iname "dkms.conf" -o -iname "*.ko*" -o -iname "Makefile" -o -iname "*.c" \) 2>/dev/null | head -30
  for f in $(find "$X" -maxdepth 5 -name dkms.conf 2>/dev/null | head -3); do echo "-- $f"; head -40 "$f"; done

  echo "== 6. 当前 DKMS 与驱动目录 =="
  dkms status 2>&1 | head -10
  ls /var/lib/dkms 2>/dev/null | head -10
  readlink -f /usr/local/corex 2>/dev/null
  ls /usr/local/corex/bin 2>/dev/null | head -12
  ls /usr/local/corex-5.0.0/bin 2>/dev/null | head -12

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
