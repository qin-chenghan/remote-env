#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：抽取两份脚本的 vLLM 启动参数与 bench 调用细节。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

show() {
  local f="$1"
  echo "################ $(basename "$f") ################"
  echo "-- server 启动参数行 --"
  grep -nE '^\s*--[a-z]' "$f" 2>/dev/null | cut -c1-170 | head -35
  echo "-- 启动命令 --"
  grep -nE 'vllm.entrypoints.openai.api_server|"-m"|vllm serve|SERVER_PREFIX|procutil|bench_driver|bench serve' "$f" 2>/dev/null | cut -c1-170 | head -20
  echo "-- HOST_MEASURE / litehost 逻辑 --"
  grep -nE 'HOST_MEASURE|HOST_TOOLKIT|liblitehost|LIGHTHOST' "$f" 2>/dev/null | cut -c1-170 | head -15
  echo "-- taskset / 绑核 --"
  grep -nE 'taskset|CPU_RANGE|SERVER_PREFIX' "$f" 2>/dev/null | cut -c1-170 | head -10
  echo ""
}

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  show /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh
  show /home/qch/scripts/timeline_opt.sh

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
