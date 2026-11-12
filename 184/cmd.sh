#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：诊断 vllmBench_lite_opt_pgosrv.sh 的语法错误，并复核已改文件。
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
  F=/home/s00806700/litehost_perf_opt/vllmBench_lite_opt_pgosrv.sh
  echo "== 语法检查 =="
  bash -n "$F" 2>&1
  echo "rc=$?"
  echo "== 第 50-75 行 =="
  sed -n '50,75p' "$F" | cat -n
  echo "== 与备份对比（若存在）=="
  ls -l "$F".bak-* 2>&1 | tail -3
  echo "== 已修改文件的 CPU_RANGE 复核 =="
  for f in /home/qch/pmu_litehost_toolkit/vllmBench_lite_pmu.sh \
           /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt_single-case.sh \
           /home/s00806700/litehost_perf_opt/vllmBench_lite_opt.sh \
           /home/s00806700/litehost_perf_opt/vllmBench_lite_base.sh \
           /home/s00806700/litehost_perf_opt/vllmBench_lite_opt_llvm.sh; do
    printf '%s  %s\n' "$(grep -m1 '^CPU_RANGE=' "$f")" "$f"
  done
  echo "== huawei_ts_program 两份里 192-255 出现在哪 =="
  grep -n '192-255' /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh \
                   /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base.sh 2>&1 | cut -c1-160

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
