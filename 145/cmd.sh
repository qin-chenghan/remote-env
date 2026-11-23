#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。核对两次采集是否用了绑核、是否零编译、以及各自的启动耗时。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
VB=/home/huawei_ts_program/litehost_perf_opt/vllmBench

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  for d in test test311; do
    echo "===== $d ====="
    echo "-- 绑核情况（server.log 中的 pinned 行）"
    docker exec "$C" bash -lc "grep -c 'pinned to cpu' $VB/$d/logs/server.log 2>/dev/null; grep -m2 'pinned to cpu' $VB/$d/logs/server.log 2>/dev/null"
    echo "-- 编译次数（Compiling）"
    docker exec "$C" bash -lc "grep -c 'Compiling' $VB/$d/logs/server.log 2>/dev/null || echo 0"
    echo "-- 启动到就绪（server.log 首尾时间）"
    docker exec "$C" bash -lc "
      head -1 $VB/$d/logs/server.log 2>/dev/null | cut -c1-60
      grep -m1 'Application startup complete' $VB/$d/logs/server.log 2>/dev/null | cut -c1-60
      grep -c 'No available shared memory broadcast' $VB/$d/logs/server.log 2>/dev/null || true
    "
    echo "-- mock 指纹"
    docker exec "$C" bash -lc "grep -m1 'activated' $VB/$d/logs/server.log 2>/dev/null | tail -1"
  done 2>&1 | head -30

  echo "== 缓存与残留 =="
  docker exec "$C" bash -lc '
    for c in /home/huawei_ts_program/inductor_cache_py311 /home/huawei_ts_program/inductor_cache_py312; do
      echo "$c files=$(find $c -name "*.py" 2>/dev/null | wc -l)"
    done'
  docker exec "$C" bash -lc 'pgrep -af "vllm[.]entrypoints|bench_driver" | grep -v pgrep || echo none'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
