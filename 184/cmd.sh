#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：核对 4k 环境下的优化使能情况与 timeline 是否真的采到。
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
  R=/home/qch/scripts/timeline/4k

  echo "== run dir =="
  ls -la "$R" 2>&1 | head -12
  echo "-- profile dirs --"
  find "$R/profile" -maxdepth 2 -type f -printf '%s\t%TY-%Tm-%Td %TH:%TM\t%p\n' 2>/dev/null | head -20
  echo "-- sizes --"
  du -sh "$R/profile" "$R/logs" 2>&1

  echo "== server.log: 优化迹象 =="
  grep -iE 'tcmalloc|ld.so|VLLM_HOST_OPT|host_opt|compact.greedy|sample_logits|fastpath|slot_native' "$R/logs/server.log" 2>/dev/null | cut -c1-200 | head -25

  echo "== server.log: 启动参数 =="
  grep -iE 'compilation-config|numa-bind|worker-cls|tensor_parallel|profiler' "$R/logs/server.log" 2>/dev/null | cut -c1-220 | head -12

  echo "== server.log: python / 模块路径 =="
  grep -iE 'sys.executable|python3\.[0-9]+|torch [0-9]|vllm.*0\.23|cudagraph' "$R/logs/server.log" 2>/dev/null | cut -c1-200 | head -12

  echo "== bench logs =="
  ls -l "$R/logs" 2>&1
  for b in "$R"/logs/bench*.log; do
    [ -f "$b" ] || continue
    echo "-- $(basename "$b") --"
    grep -iE 'profile|Throughput|latency|TTFT|TPOT|num_prompts|Completed' "$b" 2>/dev/null | head -12 | cut -c1-180
  done

  echo "== timeline_base.sh 关键行 =="
  grep -nE 'profile|BENCH_PROFILE_ARGS|CASES=|NUM_PROMPTS|VLLM_HOST_OPT|VLLM_COMPACT|sample_logits|compilation-config|worker-cls' \
    /home/qch/scripts/timeline_base.sh 2>/dev/null | cut -c1-180 | head -30

  echo "== 当前内核（确认仍是 4K）=="
  uname -r; getconf PAGE_SIZE

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
