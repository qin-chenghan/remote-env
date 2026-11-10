#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
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
  # 容器内没有 numactl，改用 taskset / python sched_setaffinity 绑到 cpu0。
  # 先跑一次基线、一次优化版，看输出格式并取 Step 9。

  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
cd "$P" || exit 1

echo "== 1. 绑核工具 =="
command -v taskset || echo NO_TASKSET
command -v numactl || echo NO_NUMACTL

run_pinned() {
  local bin=$1
  if command -v taskset >/dev/null 2>&1; then
    taskset -c 0 "$bin" 1
  else
    python3 -c "import os,sys; os.sched_setaffinity(0,{0}); os.execv(sys.argv[1],[sys.argv[1],\"1\"])" "$bin"
  fi
}

echo "== 2. 基线（bak_before_neon）=="
run_pinned ./fusion.unittest.bak_before_neon > /tmp/run_base.log 2>&1
echo "rc=$?"
grep "warmup" /tmp/run_base.log | tail -12
echo "-- 尾部 --"
tail -5 /tmp/run_base.log

echo "== 3. 优化版（fusion.unittest）=="
run_pinned ./fusion.unittest > /tmp/run_neon.log 2>&1
echo "rc=$?"
grep "warmup" /tmp/run_neon.log | tail -12
echo "-- 尾部 --"
tail -5 /tmp/run_neon.log

echo "== 4. Step 9 对比 =="
echo "-- base --"; grep "warmup" /tmp/run_base.log | tail -1
echo "-- neon --"; grep "warmup" /tmp/run_neon.log | tail -1
' 2>&1 | head -80

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
