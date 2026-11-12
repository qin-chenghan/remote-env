#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：检查最新 4k timeline 采集结果与优化使能证据。
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
  echo "== timeline run dirs =="
  ls -lt /home/qch/scripts/timeline/ 2>&1 | head -8

  R=$(ls -dt /home/qch/scripts/timeline/*/ 2>/dev/null | head -1)
  echo "RUN=$R"
  [ -n "$R" ] && [ -d "$R" ] || exit 0

  echo "== run dir =="
  ls -la "$R" 2>&1 | head -12
  echo "-- profile tree --"
  find "$R/profile" -type f -printf '%10s  %TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort -k3 | head -30
  echo "-- profile size --"
  du -sh "$R/profile" 2>&1

  echo "== logs =="
  ls -l "$R/logs" 2>&1

  echo "== bench log: case 标记与吞吐 =="
  grep -hE '^(INFO|WARNING).*(Request throughput|Output token throughput|Mean TTFT|Mean TPOT)|profile' "$R"/logs/bench*.log 2>/dev/null | cut -c1-200 | head -20

  echo "== server.log: profiler =="
  grep -hiE 'profiler|start_profile|stop_profile|trace' "$R/logs/server.log" 2>/dev/null | cut -c1-200 | head -15

  echo "== server.log: r10 特性 =="
  grep -hiE 'Host opt modes|metadata|compact.greedy|sample.logits|host_opt' "$R/logs/server.log" 2>/dev/null | cut -c1-200 | head -20

  echo "== server.log: tcmalloc / fastpath / 参数 =="
  grep -hiE 'tcmalloc|ld.so|slot_native|fastpath|compilation-config|numa-bind|async' "$R/logs/server.log" 2>/dev/null | cut -c1-220 | head -15

  echo "== server.log: worker python =="
  grep -oE '/opt/[^ ]*/bin/python[0-9.]*|site-packages/torch' "$R/logs/server.log" 2>/dev/null | sort -u | head -6

  echo "== script state =="
  sed -n '212,222p' /home/qch/scripts/timeline_opt.sh 2>&1 | cut -c1-160
  grep -n 'sample_logits_cudagraph' /home/qch/scripts/timeline_opt.sh 2>&1 | cut -c1-120

  echo "== kernel =="
  uname -r; getconf PAGE_SIZE

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
