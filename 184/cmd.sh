#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：取 liblitehost 实际拦截的 sync API 名单，用于对齐 trace 侧 SYNC_PATS。
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
  D=/home/huawei_ts_program/litehost_perf_opt

  echo "== 1. 对外导出符号 =="
  cat "$D/liblitehost.exports.txt" 2>/dev/null

  echo "== 2. wrappers.cpp 全文 =="
  cat "$D/liblitehost.wrappers.cpp" 2>/dev/null

  echo "== 3. litehost.c 全文 =="
  cat "$D/litehost.c" 2>/dev/null

  echo "== 4. Makefile =="
  cat "$D/Makefile" 2>/dev/null

  echo "== 5. README 里关于 S/H/G 的描述 =="
  grep -nE 'sync|S_total|H_total|G_total|TSHG|scope' "$D/README.md" 2>/dev/null | head -40

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
