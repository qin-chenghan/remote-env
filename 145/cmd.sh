#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。查清 vllm 容器里那个还在跑的 api_server 是谁的。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 进程详情 =="
  docker exec "$C" bash -lc '
    for p in $(pgrep -f "vllm.entrypoints.openai.api_server"); do
      echo "-- pid $p"
      ps -o pid,lstart,etime,stat,pcpu,args -p "$p" | cut -c1-160
    done'

  echo "== 2. 端口 =="
  ss -ltnp 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 free"

  echo "== 3. 相关日志（谁在跑）=="
  docker exec "$C" bash -lc '
    ls -lt /tmp/run_*.log 2>/dev/null | head -3
    ls -lt /home/huawei_ts_program/litehost_perf_opt/vllmBench 2>/dev/null | head -5
  ' 2>&1 | head -10

  echo "== 4. 最近日志尾部 =="
  docker exec "$C" bash -lc '
    for f in $(ls -t /tmp/run_*.log 2>/dev/null | head -2); do
      echo "--- $f"; tail -4 "$f"
    done' 2>&1 | head -12

  echo "== 5. bench_driver 是否也在跑 =="
  docker exec "$C" bash -lc 'pgrep -af "bench_driver" | grep -v pgrep || echo "no bench_driver"'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
