#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 导出 4K 基线(1109_195202) 与 64K(1110_164715) 两份 9-case 数据并核对内核证据。
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
  C=corex5-py311
  A=/home/z30059427/vllmBench/litehost_gap_20261109_195202
  B=/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261110_164715
  dex() { timeout 180 docker exec "$C" bash -c "$1"; }

  for D in "$A" "$B"; do
    echo "########## RUN $D"
    echo "--- config.txt ---"
    dex "cat $D/config.txt 2>&1"
    echo "--- 文件结构 ---"
    dex "ls -la --time-style=long-iso $D 2>&1"
    echo "--- case 数 ---"
    dex "ls $D/bs8_*.json 2>/dev/null | wc -l"
    echo "--- four_rank_totals.csv ---"
    dex "cat $D/host_summary/four_rank_totals.csv 2>&1"
    echo "--- summary.csv ---"
    dex "cat $D/summary.csv 2>&1"
    echo "--- 内核/页大小线索 ---"
    dex "grep -rhiE '6\.6\.0|uname|pagesize|64K|4K' $D/config.txt $D/logs/preflight.log $D/litehost/*/rank0_*.meta.json 2>/dev/null | head -10"
    echo "--- meta.json 头部 ---"
    dex "head -c 600 \$(ls $D/litehost/*/rank0_*.meta.json 2>/dev/null | head -1) 2>&1"
    echo
  done

  echo "########## 宿主机当前内核（供参考）"
  uname -a
  ls /boot/vmlinuz-* 2>/dev/null
  grubby --default-kernel 2>/dev/null || echo "host 无 grubby"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
