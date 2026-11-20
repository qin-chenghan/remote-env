#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。看 vllm 容器里那次 128/128 跑到哪一步、卡在哪。
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

  echo "== 1. 容器状态 =="
  docker ps --filter "name=$C" --format '{{.Names}} {{.Status}}'

  echo "== 2. 容器内进程（含运行时长和 CPU）=="
  docker exec "$C" bash -lc \
    'ps -eo pid,ppid,etime,pcpu,nlwp,args | grep -E "vllm.entrypoints|VLLM::|bench_driver|vllmBench" | grep -v grep | cut -c1-150' 2>&1 | head -12

  echo "== 3. 宿主整机负载与热点进程 =="
  uptime
  ps -eo pcpu,pmem,etime,args --sort=-pcpu 2>/dev/null | head -6 | cut -c1-140

  echo "== 4. 端口 =="
  ss -ltnp 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 空闲"

  echo "== 5. 服务健康 =="
  curl --noproxy '*' -s -o /dev/null -w 'health http_code=%{http_code}\n' --max-time 3 \
    http://127.0.0.1:8948/health 2>&1 || true
  curl --noproxy '*' -s -o /dev/null -w 'health8848 http_code=%{http_code}\n' --max-time 3 \
    http://127.0.0.1:8848/health 2>&1 || true

  echo "== 6. 最新 run 目录与日志 =="
  docker exec "$C" bash -lc '
    d=$(ls -dt /home/huawei_ts_program/litehost_perf_opt/vllmBench/*/ 2>/dev/null | head -1)
    echo "latest: $d"
    ls -lt "$d" 2>/dev/null | head -8
    echo "-- server.log 尾部"
    tail -12 "$d/logs/server.log" 2>/dev/null
    echo "-- bench 日志"
    ls "$d/logs" 2>/dev/null
    tail -12 "$d"/logs/bench_*.log 2>/dev/null
    echo "-- litehost case 状态"
    ls "$d/litehost" 2>/dev/null | head -3
    cat "$d"/litehost/*/case.json 2>/dev/null | head -20
    cat "$d"/litehost/*/window.json 2>/dev/null | head -10
  ' 2>&1 | head -45

  echo "== 7. 最近 5 分钟内被修改的文件（该 run 目录）=="
  docker exec "$C" bash -lc '
    find /home/huawei_ts_program/litehost_perf_opt/vllmBench -maxdepth 3 -mmin -5 -type f 2>/dev/null | head -10
  ' 2>&1 | head -12

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
