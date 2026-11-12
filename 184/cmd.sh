#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 本轮：1) dump 两份 vllmBench 报告  2) 输出含 G 的阶段对比（4k2 vs 64k2）
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
  D=/home/qch/scripts/timeline
  T=$D

  echo "################ PART 1: vllmBench 报告 ################"
  for f in "$D/261109_oe-2403-sp3_report.txt" "$D/261110-2403_sp3-64k-report.txt"; do
    echo ""
    echo "################ $(basename "$f") ################"
    ls -l "$f" 2>&1
    cat "$f" 2>&1
  done

  echo "== 同目录其它报告 =="
  ls -lt "$D"/*.txt 2>&1 | head -10

  echo ""
  echo "################ PART 2: 阶段对比 T/S/H/G ################"
  A=$(ls "$T"/4k2/profile/*/rank0*.pt.trace.json.gz 2>/dev/null | head -1)
  B=$(ls "$T"/64k2/profile/*/rank0*.pt.trace.json.gz 2>/dev/null | head -1)
  echo "A=$A"; echo "B=$B"
  [ -n "$A" ] && [ -n "$B" ] && python3 "$DIR/trace_phase_split.py" "$A" "$B" 4k2 64k2 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
