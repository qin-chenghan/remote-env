#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。正确深度找 run 目录；查残留 VLLM worker 的来源与状态。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
ID=py312_litehost_gap_20261124_100323

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 正确深度找 run 目录 =="
  docker exec "$C" bash -lc "find / -maxdepth 6 -type d -name '$ID' 2>/dev/null | head -5"
  docker exec "$C" bash -lc "ls -lt /home/huawei_ts_program/litehost_perf_opt/vllmBench 2>/dev/null | head -6"
  docker exec "$C" bash -lc "ls -lt /tmp/vllmBench 2>/dev/null | head -4"

  echo "== 2. 找到后的关键信息 =="
  P=$(docker exec "$C" bash -lc "find / -maxdepth 6 -type d -name '$ID' 2>/dev/null | head -1")
  echo "P=$P"
  if [ -n "$P" ]; then
    docker exec "$C" bash -lc "
      echo '-- config.txt'; cat '$P/config.txt'
      echo '-- 文件'; ls -la '$P' | head -8
      echo '-- server.log 关键行'; grep -nE 'loading took|Capturing|startup complete|pinned to cpu' '$P/logs/server.log' | head -10
    " 2>&1 | head -30
    echo "-- harness 日志（同目录外）--"
    docker exec "$C" bash -lc "ls -lt /tmp/run_*$ID*.log /tmp/run_*20261124*.log 2>/dev/null | head -4"
  fi

  echo "== 3. 残留 VLLM worker 的来源 =="
  ps -eo pid,ppid,lstart,stat,psr,pcpu,args 2>/dev/null | grep "VLLM::Worker_TP" | grep -v grep | cut -c1-140 | head -10

  echo "-- 每个残留 worker 的 cgroup（属于哪个容器）--"
  for p in $(pgrep -f "VLLM::Worker_TP" 2>/dev/null | head -8); do
    cid=$(grep -oE 'docker/[0-9a-f]{12,}' /proc/$p/cgroup 2>/dev/null | head -1 | cut -d/ -f2)
    name=$(docker ps -a --no-trunc --filter "id=$cid" --format '{{.Names}}' 2>/dev/null)
    echo "pid=$p container=${name:-$cid} state=$(awk '{print $3}' /proc/$p/stat 2>/dev/null) started=$(ps -o lstart= -p $p 2>/dev/null)"
  done

  echo "== 4. 是否有对应父进程（api_server/engine）还活着 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm[.]entrypoints|bench_driver" | grep -v pgrep || echo none'
  echo "-- 宿主全局 --"
  ps -eo pid,ppid,etime,args 2>/dev/null | grep -E "vllm[.]entrypoints|VLLM::Worker" | grep -v grep | cut -c1-130 | head -12

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
