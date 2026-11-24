#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。检查 093257 那次 py312 lite 运行；确认 py-spy/gdb 是否可用于抓栈。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
VB=/home/huawei_ts_program/litehost_perf_opt/vllmBench
ID=py312_litehost_gap_20261124_093257

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 最近几次 py312 lite 运行（config 摘要）=="
  for d in $(docker exec "$C" bash -lc "ls -dt $VB/py312_litehost_gap_* 2>/dev/null | head -4"); do
    echo "-- $d"
    docker exec "$C" bash -lc "grep -E 'test_id|prefix|prompts|started' $d/config.txt 2>/dev/null | tr '\n' ' '; echo; grep -cE 'Capturing' $d/logs/server.log 2>/dev/null; grep -m1 -oE '服务就绪 \([0-9]+s\)' $d/logs/server.log 2>/dev/null"
  done 2>&1 | head -20

  echo "== 2. 093257 那次的关键日志 =="
  docker exec "$C" bash -lc "
    f=$VB/$ID/logs/server.log
    if [ -f \$f ]; then
      grep -nE 'loading took|Capturing|startup complete|pinned to cpu|shm_broadcast|died unexpectedly' \$f | head -12
    else echo '无 server.log'; fi
    ls $VB/$ID 2>/dev/null | head -6
    cat $VB/$ID/summary.csv 2>/dev/null | cut -d, -f2,6,8,11"

  echo "== 3. 抓栈工具 =="
  command -v py-spy gdb perf 2>&1 | head -4
  docker exec "$C" bash -lc 'command -v py-spy gdb perf 2>&1 | head -4'

  echo "== 4. 当前容器状态 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm[.]entrypoints|bench_driver" | grep -v pgrep || echo idle'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "ports free"
  docker ps --filter name=vllm --format '{{.Names}} {{.Status}}'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
