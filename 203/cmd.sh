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
  # 只读：判断是否有人正在使用这台机器 / e2b 那套 docker。

  echo "== 1. 谁登录着 =="
  who 2>&1
  echo "-- w --"
  w 2>&1 | head -10
  echo "-- 最近登录 --"
  last -n 10 2>&1 | head -12

  echo "== 2. SSH 会话与远端来源 =="
  ss -tnp 2>/dev/null | grep -E ':22\b' | head -10
  ps -eo user,pid,etimes,args 2>/dev/null | grep '[s]shd:' | head -10

  echo "== 3. 有人在容器里操作吗（docker exec）=="
  ps -eo user,pid,etimes,args 2>/dev/null | grep -E '[d]ocker (exec|attach)|[d]ocker-compose' | head -10 || echo "无 docker exec/attach 进程"

  echo "== 4. 容器状态、重启次数、启动时间 =="
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}' 2>&1
  echo "-- 重启计数 --"
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    docker inspect -f '{{.Name}} restarts={{.RestartCount}} started={{.State.StartedAt}}' "$c" 2>/dev/null
  done | head -12

  echo "== 5. 容器资源占用（谁在真干活）=="
  timeout 20 docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.PIDs}}' 2>&1 | head -12

  echo "== 6. 每个运行中容器的日志最后一条时间 =="
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null | head -6); do
    echo "---- $c"
    docker logs --timestamps --tail 2 "$c" 2>&1 | tail -2
  done

  echo "== 7. docker 事件（最近 15 分钟）=="
  timeout 10 docker events --since 15m --until 1s --format '{{.Time}} {{.Type}} {{.Action}} {{.Actor.Attributes.name}}' 2>&1 | tail -20

  echo "== 8. 当前 data-root 下最近被写的文件 =="
  find /data-ssd/docker -xdev -mmin -30 -type f 2>/dev/null | head -15
  echo "-- /data-ssd 顶层最近写入 --"
  find /data-ssd -maxdepth 2 -xdev -mmin -30 -type f 2>/dev/null | head -15

  echo "== 9. 网络连接（有人在访问服务端口吗）=="
  ss -tn state established 2>/dev/null | grep -E ':(2900|30443|5432|8080|8443|1514)\b' | head -10 || echo "无相关连接"

  echo "== 10. GPU 上有没有别人在跑 =="
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | sed -n '/Processes/,$p' | head -12

  echo "== 11. 系统负载与近期登录尝试 =="
  uptime
  journalctl -u sshd --since '2 hours ago' --no-pager 2>/dev/null | grep -iE 'Accepted|session opened' | tail -8

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
