#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 本次：把 32 复制来的 CPU_RANGE=192-255 统一改为 184 的 80-159,240-319。
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
  echo "== 修改前统计 =="
  grep -rl '192-255' /home --include='vllmBench_lite*.sh' 2>/dev/null | head -20

  echo "== 执行修改 =="
  python3 "$DIR/fix_cpu_range.py" 2>&1

  echo "== 修改后复查 =="
  python3 "$DIR/scan_lite_configs.py" 2>&1 | grep -E '^BAD|^需要修正' | head -20

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
