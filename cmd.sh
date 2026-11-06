#!/usr/bin/env bash
# Agent: 每次覆盖本文件。改 SERVER，命令写进下方的标记区间。
set -uo pipefail

SERVER="184"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/$SERVER/tmp/$TS.log"
mkdir -p "$(dirname "$OUT")"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

echo
echo "结果已写入: $OUT"
