#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 在 corex5-py311 容器内跑 dry-run，确认最终 server/bench 参数，
# 并确认容器里的 vLLM 是否支持 --profiler-config / ignore_frontend。
# 纯 CPU，不启动 vllm，不动 GPU。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TARGET=/home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh
CTR=corex5-py311
PREFIX=/opt/corex311-cpython-vllm

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  echo "== 0. 容器运行时 =="
  RT=""
  for c in docker podman nerdctl; do
    command -v "$c" >/dev/null 2>&1 && { RT="$c"; break; }
  done
  echo "runtime: ${RT:-NONE}"
  if [ -n "$RT" ]; then
    "$RT" ps --format '{{.Names}}' 2>&1 | head -20
  fi

  echo "== 1. 容器内 dry-run =="
  if [ -n "$RT" ] && "$RT" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CTR"; then
    "$RT" exec "$CTR" bash -lc "cd /tmp && HOST_DRY_RUN=1 TEST_ID=dryrun_$TS bash $TARGET"
    echo "  (dry-run exit=$?)"
  else
    echo "  SKIP: 没找到容器 $CTR；请进容器后手动执行："
    echo "        cd /tmp && HOST_DRY_RUN=1 TEST_ID=dryrun_$TS bash $TARGET"
  fi

  echo "== 2. 容器内 vLLM 版本与 profiler 实现 =="
  if [ -n "$RT" ] && "$RT" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CTR"; then
    "$RT" exec "$CTR" bash -lc '
      V=$(env -u PYTHONPATH -u PYTHONHOME '"$PREFIX"'/bin/python3 -c "import os,vllm;print(vllm.__version__);print(os.path.dirname(vllm.__file__))" 2>&1)
      echo "$V"
      D=$(echo "$V" | tail -1)
      if [ -d "$D" ]; then
        echo "-- ignore_frontend 出现位置 --"
        grep -rn "ignore_frontend" "$D" --include="*.py" 2>/dev/null | head -10
        echo "-- delay/warmup/active/max_iterations --"
        grep -rn "delay_iterations\|warmup_iterations\|active_iterations\|max_iterations" "$D" --include="*.py" 2>/dev/null | head -20
        echo "-- profiler 文件 --"
        ls -l "$D/profiler" 2>/dev/null
      fi
    '
  else
    echo "  SKIP: 无容器"
  fi

  echo "== 3. GPU 占用（决定何时能真跑） =="
  if command -v ixsmi >/dev/null 2>&1; then
    ixsmi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>&1
  else
    echo "  ixsmi 不可用（宿主机），进容器查"
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
