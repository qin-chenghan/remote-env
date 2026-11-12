#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：对比 4k/4k2/64k/64k2 四份 timeline，含噪声基线。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

f0() { ls "$1"/profile/*/rank0*.pt.trace.json.gz 2>/dev/null | head -1; }

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  T=/home/qch/scripts/timeline

  echo "== 四份 run 概况 =="
  for R in 4k 4k2 64k 64k2; do
    D="$T/$R"
    echo "-- $R --"
    if [ ! -d "$D" ]; then echo "  MISSING"; continue; fi
    ls -ld "$D" "$D/profile" 2>&1 | sed 's/^/  /'
    du -sh "$D/profile" 2>&1 | sed 's/^/  /'
    for d in "$D"/profile/*/; do
      [ -d "$d" ] || continue
      echo "  $(basename "$d"): traces=$(ls "$d"/rank*.pt.trace.json.gz 2>/dev/null | wc -l) out=$(ls "$d"/profiler_out_*.txt 2>/dev/null | wc -l)"
    done
    for f in "$D"/profile/*/rank*.pt.trace.json.gz; do
      [ -f "$f" ] && { gzip -t "$f" 2>/dev/null && echo "  gzip OK $(basename "$f")" || echo "  gzip BAD $(basename "$f")"; }
    done
    echo "  -- bench --"
    grep -hE 'Request throughput|Output token throughput|Mean TTFT|Mean TPOT|P99 TPOT' "$D"/logs/bench*.log 2>/dev/null | sed 's/^/    /'
    echo "  -- counts --"
    for pat in 'Host opt modes=' 'Compact greedy mode=on' 'Sample logits graph.*status=ready' 'host attention metadata off' 'ld.so'; do
      printf '    %-45s %s\n' "$pat" "$(grep -c "$pat" "$D/logs/server.log" 2>/dev/null)"
    done
  done

  echo ""
  echo "======== 噪声基线 A: 4k vs 4k2 ========"
  A=$(f0 "$T/4k");  B=$(f0 "$T/4k2")
  echo "A=$A"; echo "B=$B"
  [ -n "$A" ] && [ -n "$B" ] && python3 "$DIR/trace_diff.py" "$A" "$B" 12 2>&1 | grep -v 'loading' || echo "SKIP"

  echo ""
  echo "======== 噪声基线 B: 64k vs 64k2 ========"
  A=$(f0 "$T/64k"); B=$(f0 "$T/64k2")
  echo "A=$A"; echo "B=$B"
  [ -n "$A" ] && [ -n "$B" ] && python3 "$DIR/trace_diff.py" "$A" "$B" 12 2>&1 | grep -v 'loading' || echo "SKIP"

  echo ""
  echo "======== 主结果: 4k2 vs 64k2 ========"
  A=$(f0 "$T/4k2"); B=$(f0 "$T/64k2")
  echo "A=$A"; echo "B=$B"
  [ -n "$A" ] && [ -n "$B" ] && python3 "$DIR/trace_diff.py" "$A" "$B" 20 2>&1 | grep -v 'loading' || echo "SKIP"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
