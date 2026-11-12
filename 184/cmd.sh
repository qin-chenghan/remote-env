#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：用 32 上的 analyze_timeline_hg.py 口径拆 4k2 / 64k2 的 H+G。
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
  T=/home/qch/scripts/timeline
  A=$(ls "$T"/4k2/profile/*/rank0*.pt.trace.json.gz 2>/dev/null | head -1)
  B=$(ls "$T"/64k2/profile/*/rank0*.pt.trace.json.gz 2>/dev/null | head -1)
  echo "A=$A"; echo "B=$B"
  [ -n "$A" ] && [ -n "$B" ] || { echo "ABORT"; exit 6; }

  for X in "$A" "$B"; do
    echo ""
    echo "################ $(basename "$(dirname "$(dirname "$X")")") ################"
    python3 "$DIR/trace_hg.py" "$X" --all-intervals --top 15 2>&1
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
