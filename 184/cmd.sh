#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 检查 4k1 这一轮的产物：配置是否与 11-14 一致、tcmalloc 是否真加载、trace 是否齐全。
# 纯 CPU，不启动 vllm，不动 GPU。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

BASE=/home/qch/scripts/litehost_perf/vllmBench

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  echo "== 0. 现有 run 目录 =="
  ls -dt "$BASE"/*/ 2>/dev/null | head -10

  R="${RUN_DIR:-$(ls -dt "$BASE"/*/ 2>/dev/null | head -1)}"
  R="${R%/}"
  echo "RUNDIR=$R"
  echo

  echo "== 1. config.txt =="
  cat "$R/config.txt" 2>&1

  echo "== 2. 关键生效配置（server.log） =="
  grep -nE "enable_prefix_caching|compact_greedy|sample_logits_cudagraph|Profiler with mode|Torch profiling enabled|profiler" "$R/logs/server.log" 2>/dev/null | head -40

  echo "== 3. server.log 里的启动命令 / 环境 =="
  grep -nE "LD_PRELOAD|tcmalloc|TCMALLOC|VLLM_HOST_OPT|TORCH_MODULE_ATTR_FASTPATH|UMD_MAXCOMMAND|api_server|--profiler-config" "$R/logs/server.log" 2>/dev/null | head -20

  echo "== 4. server.log 尾部（tcmalloc MALLOCSTATS 应在这里） =="
  tail -40 "$R/logs/server.log" 2>&1

  echo "== 5. server.log 中的错误 =="
  grep -cE "Traceback|ERROR" "$R/logs/server.log" 2>/dev/null || true
  grep -nE "Traceback|ERROR" "$R/logs/server.log" 2>/dev/null | head -20

  echo "== 6. bench 结果 =="
  cat "$R/logs/bench_"*.log 2>/dev/null | tail -30
  echo "-- summary.csv --"
  cat "$R/summary.csv" 2>/dev/null | head -5

  echo "== 7. trace 产物 =="
  find "$R/timeline" -type f -printf '%TY-%Tm-%Td %TH:%TM %12s  %p\n' 2>/dev/null | sort
  echo "-- 目录大小 --"
  du -sh "$R/timeline" 2>/dev/null

  echo "== 8. 每个 trace 文件是否非空且像 JSON =="
  for f in "$R/timeline"/*; do
    [ -f "$f" ] || continue
    printf '%s  size=%s  head=' "$(basename "$f")" "$(stat -c %s "$f")"
    head -c 60 "$f" | tr -d '\n'; echo
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
