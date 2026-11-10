#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：查 64K 内核的构建来源。
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
  echo "== build report =="
  sed -n '1,120p' /home/l30029702/261109_oe-2403-sp3_report.txt 2>&1

  echo "== kernel rpm inventory =="
  R=/home/l30029702/64k/kernel-6.6.02403_sp3_64K-6.aarch64.rpm
  echo "files: $(rpm -qpl "$R" 2>/dev/null | wc -l)"
  rpm -qpl "$R" 2>/dev/null | grep -E '^/usr/src|^/lib/modules/.*/build|Module.symvers|^/boot|^/lib/modules' | head -12
  echo "-- top-level prefixes --"
  rpm -qpl "$R" 2>/dev/null | sed 's|\(^/[^/]*/[^/]*\).*|\1|' | sort -u | head -12

  echo "== headers rpm inventory =="
  rpm -qpl /home/l30029702/64k/kernel-headers-6.6.02403_sp3_64K-6.aarch64.rpm 2>/dev/null \
    | sed 's|\(^/[^/]*/[^/]*\).*|\1|' | sort -u | head -10

  echo "== deep search for 64k source =="
  find /home -maxdepth 8 -type d \( -iname '*6.6*src*' -o -iname 'linux-6.6*' -o -iname '*64K*' \) 2>/dev/null | head -10
  find / -maxdepth 4 -type d -name 'linux-6.6.02403*' 2>/dev/null | head -5

  echo "== builder dir tree =="
  ls -la /home/l30029702/script 2>&1 | head -12

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
