#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 203 清理 corex-4.4.0（用户确认已用不上）：删前查占用，删后核对软链与空间。
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
  T=/usr/local/corex-4.4.0

  echo "== 1. 删前状态 =="
  df -h /
  du -sh "$T" 2>/dev/null
  ls -ld /usr/local/corex
  readlink -f /usr/local/corex

  echo "== 2. 是否有进程在用（文件被打开或路径在环境里）=="
  lsof +D "$T" 2>/dev/null | head -20 || true
  echo "--- 进程命令行里带 corex-4.4.0 的 ---"
  ps -eo pid,args 2>/dev/null | grep 'corex-4.4.0' | grep -v grep | head -10 || echo "无"
  echo "--- 容器挂载/环境里带 corex-4.4.0 的 ---"
  for c in $(docker ps -q 2>/dev/null); do
    docker inspect -f '{{.Name}} {{range .Mounts}}{{.Source}} {{end}}' "$c" 2>/dev/null | grep -l 'corex-4.4.0' 2>/dev/null
    docker exec "$c" bash -c "env | grep -i 'corex-4.4.0' || true" 2>/dev/null | head -2
  done
  echo "--- ld.so 缓存里是否仍登记该目录 ---"
  ldconfig -p 2>/dev/null | grep 'corex-4.4.0' | head -5 || echo "无"
  ls -l /etc/ld.so.conf.d/ 2>/dev/null | grep -i corex || echo "无 corex conf"

  echo "== 3. 执行删除 =="
  if [ -d "$T" ]; then
    rm -rf "$T" && echo "removed $T"
  else
    echo "$T 不存在，跳过"
  fi
  rm -f /etc/ld.so.conf.d/corex-4.4.0.conf.bak_500 2>/dev/null || true

  echo "== 4. 删后核对 =="
  du -sh "$T" 2>/dev/null || echo "$T 已不存在"
  ls -ld /usr/local/corex
  readlink -f /usr/local/corex
  ls /usr/local/corex/bin 2>/dev/null | head -5
  echo "--- 重建 ld 缓存（去掉已删路径）---"
  ldconfig 2>&1 | head -5; echo "ldconfig rc=$?"
  ldconfig -p 2>/dev/null | grep -c 'corex-4.4.0' || true

  echo "== 5. 空间 =="
  df -h /
  df -B1 / | tail -1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
