#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：确认当前内核实际页大小。
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
  echo "uname -r: $K"
  uname -v

  echo "== page size, host =="
  getconf PAGE_SIZE 2>&1
  getconf PAGESIZE 2>&1
  python3 -c "import os;print('sysconf SC_PAGE_SIZE',os.sysconf('SC_PAGE_SIZE'))" 2>&1
  od -An -tx1 -N4 /proc/self/pagemap 2>/dev/null | head -1

  echo "== page size, container =="
  docker exec corex5-py311 getconf PAGE_SIZE 2>&1
  docker exec corex5-py311 python3 -c "import mmap,os;print('mmap.PAGESIZE',mmap.PAGESIZE,'sysconf',os.sysconf('SC_PAGE_SIZE'))" 2>&1

  echo "== kernel config =="
  ls -l "/boot/config-$K" 2>&1
  grep -E '^CONFIG_ARM64_64K_PAGES|^CONFIG_ARM64_PAGE_SHIFT|^CONFIG_ARM64_4K_PAGES|^CONFIG_ARM64_16K_PAGES' "/boot/config-$K" 2>&1

  echo "== running kernel tristate (from /proc/config.gz if any) =="
  zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_ARM64_(4K|16K|64K)_PAGES' | head -4

  echo "== old kernel config for comparison =="
  grep -E '^CONFIG_ARM64_(4K|16K|64K)_PAGES' /boot/config-6.6.02403_sp3-64K 2>&1

  echo "== hugetlb / meminfo =="
  head -3 /proc/meminfo
  cat /proc/sys/vm/nr_hugepages 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
