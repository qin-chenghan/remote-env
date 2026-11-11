#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：列出 /home/qch/scripts 下 timeline 脚本及其配置。
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
  D=/home/qch/scripts

  echo "== files =="
  ls -l "$D"/timeline*.sh 2>&1

  for f in "$D"/timeline*.sh; do
    [ -f "$f" ] || continue
    echo ""
    echo "===== $(basename "$f") | $(wc -l < "$f") lines ====="
    echo "-- 头部注释 --"
    sed -n '1,12p' "$f" | cut -c1-160
    echo "-- 顶层变量 --"
    grep -nE '^[A-Za-z_][A-Za-z0-9_]*=' "$f" | cut -c1-160 | head -40
  done

  echo ""
  echo "== variant 与 timeline.sh 的差异（仅变量行）=="
  B="$D/timeline.sh"
  for f in "$D"/timeline*.sh; do
    [ -f "$f" ] || continue
    [ "$f" = "$B" ] && continue
    echo "-- $(basename "$f") vs timeline.sh --"
    diff <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$B" 2>/dev/null | cut -d= -f1) \
         <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$f" 2>/dev/null | cut -d= -f1) 2>&1 | head -20
    diff <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$B" 2>/dev/null) \
         <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$f" 2>/dev/null) 2>&1 | head -25
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
