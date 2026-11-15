#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 对齐 vllmBench_lite_timeline.sh 到 huawei_ts_program 的 vllmBench_lite_opt.sh：
# 先确认 lite 侧 bench 客户端怎么触发 profiler（bench_driver.py 是否支持 --profile，
# 以及 vLLM 的 ignore_frontend/active_iterations 迭代控制是什么语义）。
# 纯 CPU，不启动 vllm，不动 GPU。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

PREFIX="${PREFIX:-/opt/corex311-cpython-vllm}"
PY="$PREFIX/bin/python3"
TOOLKIT=/home/huawei_ts_program/litehost_perf_opt

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  echo "== 0. toolkit 目录 =="
  ls -l "$TOOLKIT" 2>/dev/null || echo "MISSING $TOOLKIT"

  echo "== 1. bench_driver.py 全文 =="
  if [ -f "$TOOLKIT/bench_driver.py" ]; then
    cat -n "$TOOLKIT/bench_driver.py"
  else
    echo "MISSING $TOOLKIT/bench_driver.py"
  fi

  echo "== 2. LightHostWorker 是否感知 profiler =="
  W=$(ls "$TOOLKIT"/light_host_worker.py "$TOOLKIT"/litehost_compat_slim/light_host_worker.py 2>/dev/null | head -1)
  echo "worker file: ${W:-MISSING}"
  if [ -n "${W:-}" ]; then
    grep -n "profil\|torch.profiler\|Profiler" "$W" || echo "  (no profiler references)"
  fi

  echo "== 3. vLLM profiler 实现：ignore_frontend / 迭代控制 =="
  VLLM_DIR=$(env -u PYTHONPATH -u PYTHONHOME "$PY" -c 'import os,vllm;print(os.path.dirname(vllm.__file__))' 2>/dev/null)
  echo "vllm dir: ${VLLM_DIR:-UNRESOLVED}"
  if [ -n "${VLLM_DIR:-}" ]; then
    echo "-- 含 ignore_frontend 的文件 --"
    grep -rln "ignore_frontend" "$VLLM_DIR" 2>/dev/null | head -20
    echo "-- 含 active_iterations 的文件 --"
    grep -rln "active_iterations" "$VLLM_DIR" 2>/dev/null | head -20
    echo "-- 定义/使用点（带 3 行上下文） --"
    grep -rn "ignore_frontend\|delay_iterations\|warmup_iterations\|active_iterations\|max_iterations" \
      "$VLLM_DIR" --include='*.py' 2>/dev/null | head -60
    echo "-- profiler 目录 --"
    ls -l "$VLLM_DIR/profiler" 2>/dev/null
  fi

  echo "== 4. /start_profile /stop_profile 路由 =="
  if [ -n "${VLLM_DIR:-}" ]; then
    grep -rn "start_profile\|stop_profile" "$VLLM_DIR/entrypoints" --include='*.py' 2>/dev/null | head -30
  fi

  echo "== 5. bench serve 客户端的 --profile 定义 =="
  if [ -n "${VLLM_DIR:-}" ]; then
    grep -rn "\-\-profile\b\|profile:" "$VLLM_DIR/benchmarks" --include='*.py' 2>/dev/null | head -20
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
