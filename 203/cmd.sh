#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 203 docker 盘点（只读）：容器/镜像清单、占用、可回收项；不做任何删除。
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
  echo "== 1. 空间现状（docker 在 /home/docker）=="
  df -h / /home | tail -3
  docker info 2>/dev/null | grep 'Docker Root Dir'
  docker system df 2>&1 | head -8

  echo "== 2. 容器全清单（含可写层大小）=="
  docker ps -a -s --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Size}}' 2>&1 | head -40

  echo "== 3. 镜像全清单 =="
  docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}' 2>&1 | head -30
  echo "--- dangling（无 tag）---"
  docker images -f dangling=true --format '{{.ID}}  {{.Size}}  {{.CreatedSince}}' 2>&1 | head -20
  echo "--- build cache ---"
  docker system df -v 2>&1 | sed -n '/Build cache/,$p' | head -10

  echo "== 4. 未被运行中容器使用的镜像（候选）=="
  used=$(docker ps --format '{{.Image}}' 2>/dev/null | sort -u)
  docker images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}} {{.CreatedSince}}' 2>/dev/null | while read -r tag id size since; do
    printf '%s\n' "$used" | grep -qxF "$tag" || printf '%s | %s | %s | %s\n' "$tag" "$id" "$size" "$since"
  done | head -25

  echo "== 5. 已停止容器汇总 =="
  docker ps -a --filter status=exited --format '{{.ID}} {{.Names}} {{.Image}} {{.Status}}' 2>&1 | head -20
  echo "--- 每个已停止容器的可写层大小 ---"
  docker ps -a -s --filter status=exited --format '{{.Names}} {{.Size}}' 2>&1 | head -20

  echo "== 6. 运行中容器（不要动）=="
  docker ps --format '{{.ID}} {{.Names}} {{.Image}} {{.Status}}' 2>&1 | head -15

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
