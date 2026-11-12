#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：对比 vllmBench_lite_opt.sh 与 timeline_opt.sh 的启动/bench 参数。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

show() {
  local f="$1"
  echo "################ $f ################"
  ls -l "$f" 2>&1
  echo "-- 默认参数 --"
  grep -nE '^[A-Z_]+="\${\s*[A-Z_]+:?-' "$f" 2>/dev/null | cut -c1-170 | head -25
  echo "-- SERVER_ARGS --"
  awk '/SERVER_ARGS=(/,/^ *\)/' "$f" 2>/dev/null | cut -c1-170 | head -40
  echo "-- 服务端 env 数组 --"
  awk '/SERVER_EXTRA_ENV=(/,/^ *\)/' "$f" 2>/dev/null | cut -c1-170 | head -25
  awk '/SERVER_ENV=(/,/^ *\)/' "$f" 2>/dev/null | cut -c1-170 | head -25
  echo "-- env / 预载 / 绑核 --"
  grep -nE 'LD_PRELOAD|TCMALLOC|VLLM_[A-Z_]+=|UMD_|TORCH_MODULE|taskset|CPU_RANGE|ENABLE_TASKSET|numa-bind' "$f" 2>/dev/null | cut -c1-170 | head -30
  echo "-- bench 调用 --"
  grep -nE 'bench_driver|vllm.entrypoints.cli.main bench|bench serve|num_prompts|num-warmups|max-concurrency|random_input|random_output|dataset_name|--profile|profiler-config' "$f" 2>/dev/null | cut -c1-170 | head -30
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
