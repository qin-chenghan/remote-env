#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：找用户命名的 4k / 4k2 / 64k / 64k2 四份 run 及其产物。
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
  echo "== 1. 所有 vllmBench 目录 =="
  find /home /usr/local -maxdepth 6 -type d -name 'vllmBench' 2>/dev/null | head -10

  echo "== 2. 名字带 4k/64k 的目录 =="
  find /home /usr/local -maxdepth 6 -type d \( -iname '*4k*' -o -iname '*64k*' \) 2>/dev/null | head -30

  echo "== 3. litehost_perf_opt 下的 vllmBench 列表 =="
  ls -lat --time-style=long-iso /home/huawei_ts_program/litehost_perf_opt/vllmBench 2>/dev/null | head -15

  echo "== 4. 各 vllmBench 下的 run 名字 =="
  for v in $(find /home /usr/local -maxdepth 6 -type d -name 'vllmBench' 2>/dev/null); do
    echo "---- $v"; ls -1 "$v" 2>/dev/null | head -12
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
