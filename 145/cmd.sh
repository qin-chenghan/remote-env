#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读诊断——新容器 vllm 里起脚本报 Address already in use，定位谁占端口。
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

  echo "== 1. 宿主上的监听端口（8848/8948/8000/8080）=="
  ss -ltnp 2>/dev/null | grep -E ':(8848|8948|8000|8080)\b' || echo "以上端口均空闲"

  echo "== 2. 所有容器 =="
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | head -20

  echo "== 3. 新容器 vllm 的配置 =="
  docker inspect vllm --format \
    'Image={{.Config.Image}} Network={{.HostConfig.NetworkMode}} Pid={{.HostConfig.PidMode}} CapAdd={{.HostConfig.CapAdd}} SecurityOpt={{.HostConfig.SecurityOpt}}' 2>&1
  docker inspect vllm --format '{{json .HostConfig.Binds}}' 2>&1

  echo "== 4. 谁在监听这些端口（含容器归属）=="
  for port in 8848 8948; do
    pids=$(ss -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print $0}')
    echo "-- port $port: $pids"
  done
  echo "-- 当前 vLLM 相关进程 --"
  ps -eo pid,args 2>/dev/null | grep -E "vllm.entrypoints|VLLM::" | grep -v grep | cut -c1-120 | head -10

  echo "== 5. 进程属于哪个容器 =="
  for p in $(pgrep -f "vllm.entrypoints.openai.api_server" 2>/dev/null); do
    echo "-- pid $p --"
    grep -m1 "docker\|containerd" /proc/$p/cgroup 2>/dev/null | cut -c1-160
    docker inspect vllm --format 'vllm container id={{.Id}}' 2>/dev/null
  done

  echo "== 6. vllm 容器内的端口与进程 =="
  docker exec vllm bash -lc \
    'ss -ltnp 2>/dev/null | grep -E ":(8848|8948)\b" || echo "容器内无监听"; pgrep -af "vllm.entrypoints|bench_driver" | head -5' 2>&1

  echo "== 7. 最近的启动日志 =="
  ls -t /home/huawei_ts_program/litehost_perf_opt/vllmBench/ 2>/dev/null | head -3
  for f in $(ls -t /home/huawei_ts_program/litehost_perf_opt/vllmBench/*/logs/server.log 2>/dev/null | head -2); do
    echo "--- $f"; grep -iE "address already in use|error|EADDRINUSE" "$f" | tail -5
  done
  ls -t /home/qch/transfer/*.log 2>/dev/null | head -3

  echo "== 8. 正在跑的服务进程归属 =="
  for c in vllm corex5-py311-mock; do
    echo "-- $c"
    docker exec "$c" bash -lc 'pgrep -af "api_server|bench_driver" | head -4' 2>&1 | head -5
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
