#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：按 prefill/decode 切分，比较 4k2 与 64k2 的 T/S/H。
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
  [ -n "$A" ] && [ -n "$B" ] || { echo "ABORT: trace 缺失"; exit 6; }

  python3 "$DIR/trace_phase_split.py" "$A" "$B" 4k2 64k2 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
