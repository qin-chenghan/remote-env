#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：等待 lite145_1438 结束，打印 H/G 汇总（只读）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TEST_ID=lite145_1438
TOOLS=/home/huawei_ts_program/litehost_perf_opt
RUN_DIR="$TOOLS/vllmBench/$TEST_ID"
LOG=/home/qch/transfer/run_${TEST_ID}.log

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 等待完成（最多 8 分钟）=="
  for i in $(seq 1 16); do
    [ -f "$RUN_DIR/summary.csv" ] && { echo "summary.csv 已生成"; break; }
    [ "$i" -eq 1 ] && echo "开始等待（30s/轮）"
    sleep 30
  done
  [ -f "$RUN_DIR/summary.csv" ] || echo "!! 仍未完成"

  echo "== 2. 运行日志尾部 =="
  tail -20 "$LOG" 2>/dev/null

  echo "== 3. 吞吐与延迟 =="
  [ -f "$RUN_DIR/summary.csv" ] && cat "$RUN_DIR/summary.csv"

  echo "== 4. H / H+G 报告 =="
  [ -f "$RUN_DIR/host_summary/report.txt" ] && cat "$RUN_DIR/host_summary/report.txt"
  ls -lh "$RUN_DIR/host_summary" 2>/dev/null | head -8

  echo "== 5. 状态 =="
  docker exec corex5-py311-mock bash -lc 'pgrep -af "vllm.entrypoints.openai.api_server" | head -2' 2>/dev/null
  free -g | sed -n 2p

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
