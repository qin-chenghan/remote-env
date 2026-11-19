#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：等待 mock145_1355 跑完并汇总结果（只读，不启动任何东西）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TEST_ID=mock145_1355
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

  echo "== 1. 等待完成（最多 8 分钟）=="
  for i in $(seq 1 16); do
    if [ -f "$RUN_DIR/summary.csv" ]; then
      echo "summary.csv 已生成"
      break
    fi
    if ! pgrep -f "vllm.entrypoints.openai.api_server" >/dev/null 2>&1 \
       && [ "$i" -gt 1 ]; then
      echo "服务已退出但没有 summary.csv，可能失败"
      break
    fi
    [ "$i" -eq 1 ] && echo "开始等待..."
    sleep 30
  done

  echo "== 2. 运行日志尾部 =="
  tail -25 "$LOG" 2>/dev/null || echo "(缺 $LOG)"

  echo "== 3. 结果 =="
  if [ -f "$RUN_DIR/summary.csv" ]; then
    cat "$RUN_DIR/summary.csv"
    ls -lh "$RUN_DIR"/*.json 2>/dev/null | tail -3
  else
    echo "还没有 summary.csv"
  fi

  echo "== 4. trace 产物 =="
  ls -lh "$RUN_DIR/timeline" 2>/dev/null | head -12
  du -sh "$RUN_DIR" 2>/dev/null

  echo "== 5. 进程与资源 =="
  docker exec "$CONTAINER" bash -lc 'pgrep -af "vllm.entrypoints.openai.api_server" | head -2' 2>/dev/null
  free -g | sed -n 1,2p
  df -h /home | tail -1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
