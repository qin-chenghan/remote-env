#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：看 run 目录结构，用于修正进度/ETA 脚本。
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
  RUN=$(docker exec corex5-py311 bash -c \
    "S=\$(pgrep -f bench_driver.py | head -1); tr '\0' '\n' < /proc/\$S/environ | sed -n 's/^LIGHTHOST_SESSION=//p' | head -1" 2>/dev/null)
  R=${RUN%/*}
  echo "RUN=$R"

  echo "== tree depth 2 =="
  docker exec corex5-py311 bash -c "for d in '$R'/*/; do echo \"\$(stat -c '%y' \"\$d\" | cut -d. -f1)  \$d\"; done" 2>&1 | head -10

  echo "== litehost subdirs =="
  docker exec corex5-py311 bash -c "for d in '$R'/litehost/*/; do [ -d \"\$d\" ] && echo \"\$(stat -c '%y' \"\$d\" | cut -d. -f1)  \$(basename \"\$d\")\"; done" 2>&1 | head -15

  echo "== control subdirs =="
  docker exec corex5-py311 bash -c "for d in '$R'/control/*/; do [ -d \"\$d\" ] && echo \"\$(stat -c '%y' \"\$d\" | cut -d. -f1)  \$(basename \"\$d\")\"; done" 2>&1 | head -10

  echo "== files inside litehost =="
  docker exec corex5-py311 bash -c "find '$R/litehost' -maxdepth 2 -type f | head -20" 2>&1
  echo "== files inside control =="
  docker exec corex5-py311 bash -c "find '$R/control' -maxdepth 2 -type f | head -10" 2>&1

  echo "== logs =="
  docker exec corex5-py311 bash -c "ls -l '$R/logs'" 2>&1

  echo "== session.json keys =="
  docker exec corex5-py311 bash -c "head -c 400 '$R/session.json' 2>/dev/null" 2>&1

  echo "== bench log tail (if any) =="
  docker exec corex5-py311 bash -c "ls '$R/logs'" 2>&1 | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
