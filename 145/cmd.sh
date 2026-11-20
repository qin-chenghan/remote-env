#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。二次诊断——容器网络/挂载、遗留 server 归属、vllm 容器内的失败日志。
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

  echo "== 1. 容器完整 ID 与网络/挂载 =="
  docker ps -a --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}' | head -8
  for c in vllm corex5-py311-mock; do
    echo "-- $c"
    docker inspect "$c" --format \
      'Net={{.HostConfig.NetworkMode}} Pid={{.HostConfig.PidMode}} Binds={{json .HostConfig.Binds}} CapAdd={{.HostConfig.CapAdd}}'
  done

  echo "== 2. 所有 api_server 进程 → 归属容器 =="
  for p in $(pgrep -f "vllm.entrypoints.openai.api_server" 2>/dev/null); do
    cid=$(grep -oE 'docker/[0-9a-f]{12,}' /proc/$p/cgroup 2>/dev/null | head -1 | cut -d/ -f2)
    name=$(docker ps -a --no-trunc --filter "id=$cid" --format '{{.Names}}' 2>/dev/null)
    echo "pid=$p container=${name:-$cid} args=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-160)"
  done

  echo "== 3. 各容器内部的监听端口 =="
  for c in vllm corex5-py311-mock; do
    echo "-- $c"
    docker exec "$c" bash -lc 'ss -ltn 2>/dev/null | head -6' 2>&1 | head -7
  done

  echo "== 4. vllm 容器的文件系统实况 =="
  docker exec vllm bash -lc '
    echo "pwd=$(pwd)"; ls /home 2>/dev/null | head -5
    ls -la /home/huawei_ts_program 2>/dev/null | head -6
    ls -la /home/huawei_ts_program/litehost_perf_opt 2>/dev/null | head -6
  ' 2>&1 | head -18

  echo "== 5. vllm 容器内搜 Address already in use =="
  docker exec vllm bash -lc '
    grep -rIl "Address already in use" /home /tmp /root /var/log 2>/dev/null | head -5
  ' 2>&1 | head -6

  echo "== 6. vllm 容器内最近的日志尾部 =="
  docker exec vllm bash -lc '
    for f in $(ls -t /home/huawei_ts_program/litehost_perf_opt/vllmBench/*/logs/server.log 2>/dev/null | head -2); do
      echo "--- $f"; tail -6 "$f"
    done
    ls -t /tmp/*.log /home/*.log 2>/dev/null | head -3
  ' 2>&1 | head -25

  echo "== 7. 遗留 server 的启动时间 =="
  ps -eo pid,lstart,args 2>/dev/null | grep "vllm.entrypoints.openai.api_server" | grep -v grep | cut -c1-140

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
