#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：检查 4k / 64k 两份 timeline 的完整性与关键指标。
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
  for T in 4k 64k; do
    R=/home/qch/scripts/timeline/$T
    echo ""
    echo "================ $T ================"
    if [ ! -d "$R" ]; then echo "MISSING: $R"; continue; fi

    echo "-- 目录时间 --"
    ls -ld "$R" "$R"/profile "$R"/logs 2>&1

    echo "-- 体量 --"
    du -sh "$R" "$R/profile" "$R/logs" 2>&1

    echo "-- profile 文件 --"
    find "$R/profile" -type f -printf '%10s  %TH:%TM  %p\n' 2>/dev/null | sort -k3 | head -25

    echo "-- 每个 case 的 rank trace 数 --"
    for d in "$R"/profile/*/; do
      [ -d "$d" ] || continue
      n=$(ls "$d"/rank*.pt.trace.json.gz 2>/dev/null | wc -l)
      out=$(ls "$d"/profiler_out_*.txt 2>/dev/null | wc -l)
      echo "  $(basename "$d"): traces=$n profiler_out=$out"
    done

    echo "-- gzip 完整性 --"
    for f in "$R"/profile/*/rank*.pt.trace.json.gz; do
      [ -f "$f" ] || continue
      gzip -t "$f" 2>/dev/null && echo "  OK   $(basename "$(dirname "$f")")/$(basename "$f")" || echo "  BAD  $f"
    done

    echo "-- trace JSON 首尾 --"
    for f in $(ls "$R"/profile/*/rank*.pt.trace.json.gz 2>/dev/null | head -2); do
      echo "  $(basename "$f"): head=$(zcat "$f" 2>/dev/null | head -c 60 | tr -d '\n') ... tail=$(zcat "$f" 2>/dev/null | tail -c 60 | tr -d '\n')"
    done

    echo "-- bench 指标 --"
    for b in "$R"/logs/bench*.log; do
      [ -f "$b" ] || continue
      echo "  $(basename "$b")"
      grep -E 'Request throughput|Output token throughput|Total token throughput|Mean TTFT|Mean TPOT|P99 TPOT|Starting profiler|Stopping profiler|num_prompts' "$b" 2>/dev/null | sed 's/^/    /'
    done

    echo "-- server.log 关键证据 --"
    grep -hiE 'Host opt modes|Compact greedy mode|Sample logits graph|Sample logits cudagraph|host attention metadata off|Using ILU_FLASH_ATTN|Torch profiling enabled|Starting profiler|Stopping profiler' "$R/logs/server.log" 2>/dev/null | sed 's/^/  /' | cut -c1-190 | head -30

    echo "-- 计数 --"
    echo "  metadata_off=$(grep -c 'host attention metadata off' "$R/logs/server.log" 2>/dev/null)"
    echo "  host_opt_lines=$(grep -c 'Host opt modes=' "$R/logs/server.log" 2>/dev/null)"
    echo "  compact_greedy_on=$(grep -c 'Compact greedy mode=on' "$R/logs/server.log" 2>/dev/null)"
    echo "  sample_graph_ready=$(grep -c 'Sample logits graph.*status=ready' "$R/logs/server.log" 2>/dev/null)"
    echo "  profiler_start=$(grep -c 'Starting profiler' "$R/logs/server.log" 2>/dev/null)"
    echo "  ldso_err=$(grep -c 'ld.so' "$R/logs/server.log" 2>/dev/null)"
  done

  echo ""
  echo "================ 内核现状 ================"
  uname -r; getconf PAGE_SIZE

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
