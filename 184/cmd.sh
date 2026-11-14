#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：取 litehost 的 TSHG 权威定义（lh_runtime/lhctl/analyze 及相关文档）。
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

  echo "== 1. 工具目录清单 =="
  ls -l --time-style=long-iso "$D" 2>/dev/null | head -20
  echo "--- 相关文档 ---"
  find "$D" /home/qch/scripts -maxdepth 2 -iname '*.md' -o -maxdepth 2 -iname 'README*' 2>/dev/null | head -10

  echo "== 2. lh_runtime.py 全文 =="
  cat "$D/lh_runtime.py" 2>/dev/null

  echo "== 3. lh_common.py 全文 =="
  cat "$D/lh_common.py" 2>/dev/null

  echo "== 4. lhctl.py 全文 =="
  cat "$D/lhctl.py" 2>/dev/null

  echo "== 5. analyze_litehost.py 全文 =="
  cat "$D/analyze_litehost.py" 2>/dev/null

  echo "== 6. native 侧相关源码/头文件 =="
  find "$D" -maxdepth 2 \( -name '*.cpp' -o -name '*.c' -o -name '*.h' -o -name '*.txt' \) 2>/dev/null | head -15

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
