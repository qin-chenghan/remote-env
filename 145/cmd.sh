#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：等待 pin145_1608 结束，确认四个 rank 的绑核并打印 H/G（只读）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TEST_ID=pin145_1608
TOOLS=/home/huawei_ts_program/litehost_perf_opt
RUN_DIR="$TOOLS/vllmBench/$TEST_ID"
LOG=/home/qch/transfer/run_${TEST_ID}.log
CONTAINER=corex5-py311-mock

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 绑核确认 =="
  grep -E "pinned to cpu" "$LOG" 2>/dev/null || echo "(日志里还没有 pinned 行)"

  echo "== 2. 进程实际亲和（运行中才有效）=="
  docker exec "$CONTAINER" bash -lc '
    for p in $(pgrep -f "VLLM::Worker_TP" 2>/dev/null); do
      echo -n "$(cat /proc/$p/comm 2>/dev/null) pid=$p: "
      grep Cpus_allowed_list /proc/$p/status 2>/dev/null
    done
  ' 2>/dev/null | head -8

  echo "== 3. 等待完成（最多 8 分钟）=="
  for i in $(seq 1 16); do
    [ -f "$RUN_DIR/summary.csv" ] && { echo "summary.csv 已生成"; break; }
    [ "$i" -eq 1 ] && echo "开始等待（30s/轮）"
    sleep 30
  done
  [ -f "$RUN_DIR/summary.csv" ] || echo "!! 仍未完成"

  echo "== 4. 运行日志尾部 =="
  tail -16 "$LOG" 2>/dev/null

  echo "== 5. H/G 报告 =="
  [ -f "$RUN_DIR/host_summary/report.txt" ] && tail -12 "$RUN_DIR/host_summary/report.txt"

  echo "== 6. 吞吐 =="
  [ -f "$RUN_DIR/summary.csv" ] && cut -d, -f2,5,6,8,11 "$RUN_DIR/summary.csv"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
