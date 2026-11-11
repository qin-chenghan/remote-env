#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：确认 bench 脚本的开关注入点（env / CLI）。
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
  D=/home/huawei_ts_program/litehost_perf_opt

  for f in "$D/vllmBench_lite_base.sh" "$D/vllmBench_lite_opt.sh"; do
    echo ""
    echo "===== $(basename "$f") ====="
    echo "-- 可注入的环境点 --"
    grep -nE 'COMPILATION_CONFIG_EXTRA|SERVER_EXTRA_ENV|HEAD_EXTRA|EXTRA_ARGS|PREFIX=|PYTHON_BIN=|HOST_MEASURE=|CPU_RANGE=|GPU_LIST=|PORT=|MODEL_PATH=' "$f" | cut -c1-170 | head -20

    echo "-- 硬编码的 VLLM_* --"
    grep -nE '^\s*VLLM_[A-Z_]+=|VLLM_HOST|TORCH_MODULE_ATTR|UMD_' "$f" | cut -c1-170 | head -15

    echo "-- server 参数里的 compilation-config / numa --"
    grep -nE 'compilation-config|numa-bind|profiler-config|worker-cls' "$f" | cut -c1-170 | head -10
  done

  echo ""
  echo "== multi engine 当前值 =="
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>&1
  modinfo -p iluvatar 2>/dev/null | grep -i -E 'multi|engine' | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
