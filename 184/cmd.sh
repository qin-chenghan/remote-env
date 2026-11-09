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
  # 只读：看当前谁在用 184、跑的是什么、跑了多久。

  CON=corex5-py311

  echo "== 1. 登录会话 =="
  who 2>/dev/null || true
  echo
  w 2>/dev/null | head -20 || true

  echo "== 2. 宿主高占用进程 =="
  ps -eo user,pid,etimes,pcpu,pmem,args --sort=-pcpu 2>/dev/null | head -25

  echo "== 3. 与 vllm/bench 相关的进程 =="
  pgrep -af "vllmBench|bench_driver|vllm.entrypoints|api_server" 2>/dev/null | grep -v pgrep | head -20

  echo "== 4. 容器内进程（含启动时间）=="
  docker exec "$CON" sh -c "ps -eo pid,user,lstart,etimes,pcpu,args 2>/dev/null | grep -E 'vllm|bench_driver|benchmark|python' | grep -v grep | head -30"

  echo "== 5. GPU 占用 =="
  docker exec "$CON" sh -c "ixsmi 2>/dev/null | head -60 || echo 'ixsmi unavailable'"

  echo "== 6. 最近的 bench 运行目录 =="
  ls -lt --time-style=long-iso /home/huawei_ts_program/litehost_perf_opt/vllmBench 2>/dev/null | head -12
  find /home -maxdepth 4 -type d -name "litehost_gap_2026*" -newermt "2026-11-08" 2>/dev/null | head -10

  echo "== 7. 容器状态 =="
  docker ps --format '{{.Names}}\t{{.Status}}' | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
