#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。检查 test（py312）与 test311（py311）两次采集的结果与异常。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
TOOLS=/home/huawei_ts_program/litehost_perf_opt
VB=$TOOLS/vllmBench

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 找 run 目录 =="
  docker exec "$C" bash -lc "
    ls -d $VB/test $VB/test311 2>/dev/null
    ls -d $VB/*test* 2>/dev/null | head -8
    ls -lt /tmp/run_test*.log 2>/dev/null | head -4
  " 2>&1 | head -14

  for d in test test311; do
    echo "== 2.$d 配置与结果 =="
    docker exec "$C" bash -lc "
      echo '--- config.txt'; cat $VB/$d/config.txt 2>/dev/null
      echo '--- summary.csv'; cat $VB/$d/summary.csv 2>/dev/null
      echo '--- 目录内容'; ls -la $VB/$d 2>/dev/null | head -8
    " 2>&1 | head -22
  done

  echo "== 3. litehost H/G 报告（若有）=="
  for d in test test311; do
    docker exec "$C" bash -lc "
      if [ -f $VB/$d/host_summary/report.txt ]; then
        echo '--- $d'; tail -8 $VB/$d/host_summary/report.txt
      else echo '$d: 无 host_summary'; fi"
  done 2>&1 | head -24

  echo "== 4. server.log 异常 =="
  for d in test test311; do
    docker exec "$C" bash -lc "
      f=$VB/$d/logs/server.log
      if [ -f \$f ]; then
        echo '--- $d'
        grep -niE 'error|traceback|exception|failed' \$f | tail -5
        grep -cE 'Compiling' \$f || true
      else echo '$d: 无 server.log'; fi"
  done 2>&1 | head -20

  echo "== 5. 缓存现状 =="
  docker exec "$C" bash -lc '
    for c in /home/huawei_ts_program/inductor_cache_py311 /home/huawei_ts_program/inductor_cache_py312; do
      echo "$c files=$(find $c -name "*.py" 2>/dev/null | wc -l)"
    done'

  echo "== 6. 残留进程与端口 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm[.]entrypoints|bench_driver" | grep -v pgrep || echo none'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "ports free"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
