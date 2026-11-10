#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：查找 6.6.02403_sp3-64K 的内核源码/构建树。
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
  echo "== builder dir =="
  ls -la /home/l30029702/64k 2>&1 | head -30

  echo "== any prepared kernel tree =="
  find /home /opt /usr/src -maxdepth 6 -name 'Module.symvers' 2>/dev/null | head -10

  echo "== any linux source dirs =="
  find /home /opt /usr/src -maxdepth 5 -type d \( -name 'linux-*' -o -name 'linux' -o -name '*kernel*src*' \) 2>/dev/null | head -15

  echo "== 64K config in any tree =="
  for f in $(find /home /opt /usr/src -maxdepth 6 -name '.config' 2>/dev/null | head -20); do
    grep -q 'CONFIG_ARM64_64K_PAGES=y' "$f" 2>/dev/null && echo "64K: $f  ($(stat -c %y "$f"))"
  done

  echo "== rpm contents hint =="
  rpm -qpl /home/l30029702/64k/kernel-headers-6.6.02403_sp3_64K-6.aarch64.rpm 2>&1 | head -15
  echo "--- kernel rpm ---"
  rpm -qpl /home/l30029702/64k/kernel-6.6.02403_sp3_64K-6.aarch64.rpm 2>&1 | grep -E 'build|source|devel' | head -10

  echo "== who built it (history hint) =="
  ls -la /home/l30029702 2>&1 | head -20

  echo "== existing trees for 145 =="
  ls -l /usr/src/linux-6.6.0-145.3.37.168.oe2403sp3.aarch64/Module.symvers 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
