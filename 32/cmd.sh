#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 32 上安装 r14 前置检查：找到两份文件、确认容器与 venv、确认没人用。
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
  echo "== 1. 主机与用户 =="
  uname -a
  whoami
  echo "HOME=$HOME"

  echo "== 2. 找 r14 相关文件 =="
  ls -lat "$HOME/Downloads" "$HOME/transfer" /home/qch/transfer 2>/dev/null | head -30
  find /home -maxdepth 4 \( -iname '*host-opt*' -o -iname '*r14*' \) -not -path '*/.git/*' 2>/dev/null | head -20
  find /home -maxdepth 5 -name '*.zip' -newermt '2026-11-10' 2>/dev/null | head -20

  echo "== 3. 容器 =="
  docker ps -a --format '{{.ID}}  {{.Names}}  {{.Image}}  {{.Status}}' 2>&1 | head -20

  echo "== 4. 容器内的 venv 与已装版本 =="
  for c in $(docker ps -q 2>/dev/null); do
    n=$(docker inspect -f '{{.Name}}' "$c")
    echo "---- $n"
    docker exec "$c" bash -c "ls -d /opt/corex311* 2>/dev/null" 2>&1
    docker exec "$c" bash -c "for v in /opt/corex311 /opt/corex311-cpython-vllm; do [ -x \$v/bin/pip ] && { echo \"== \$v\"; \$v/bin/pip list 2>/dev/null | grep -iE '^vllm |metadata'; ls -ld \$v/lib/python3.11/site-packages/.host-opt-pr-backup 2>/dev/null; }; done" 2>&1
  done

  echo "== 5. 是否有服务在跑 =="
  ps -eo pid,etime,args 2>/dev/null | grep -E 'vllm|api_server|ixsys' | grep -v grep | head -10
  for c in $(docker ps -q 2>/dev/null); do
    echo "-- $(docker inspect -f '{{.Name}}' "$c")"
    docker exec "$c" bash -c "ps -eo pid,etime,args | grep -E 'vllm|api_server|benchmark' | grep -v grep | head -5"
  done

  echo "== 6. 编译环境与空间 =="
  for c in $(docker ps -q 2>/dev/null); do
    echo "-- $(docker inspect -f '{{.Name}}' "$c")"
    docker exec "$c" bash -c "which cmake gcc g++ ninja 2>&1 | head -5; cmake --version 2>/dev/null | head -1; df -h /opt | tail -1"
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
