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
  # 只读：在 145 宿主机（容器外）与其它运行中的容器里搜 clamp_to_u8。

  echo "== 1. 宿主机搜索（跳过 docker 存储目录）=="
  timeout 120 grep -rln "clamp_to_u8\|kUint8ToFloatDivisor" \
    /home /opt /data /root /usr/local \
    --exclude-dir=docker --exclude-dir=overlay2 --exclude-dir=containerd 2>/dev/null | head -10
  echo "host_search_done"

  echo "== 2. 运行中的容器 =="
  docker ps --format '{{.Names}}	{{.Image}}' 2>&1 | head -20

  echo "== 3. 其它容器内搜索（限源码类文件）=="
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    R=$(timeout 40 docker exec "$c" bash -lc \
      'grep -rln --include=*.cpp --include=*.h --include=*.cc --include=*.hpp clamp_to_u8 /opt /home 2>/dev/null | head -3' 2>/dev/null)
    if [ -n "$R" ]; then
      echo "--- $c ---"
      echo "$R"
    fi
  done
  echo "container_search_done"

  echo "== 4. 宿主机 /home 下近期改动的源码 =="
  find /home -maxdepth 4 \( -name '*.cpp' -o -name '*.h' \) -newermt '-14 days' 2>/dev/null | head -10
  echo "recent_done"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
