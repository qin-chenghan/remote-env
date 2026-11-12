#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：检查 huawei_ts_program 的 vllmBench_lite_opt.sh 第 245/246 行附近的问题。
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
  F=/home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh
  echo "== 文件 =="
  ls -l "$F"
  echo "== bash -n =="
  bash -n "$F" 2>&1; echo "rc=$?"
  echo "== 第 225-260 行（带行号）=="
  sed -n '225,260p' "$F" | nl -ba -v225 | cut -c1-200
  echo "== 备份文件 =="
  ls -lt "$F".bak-* 2>&1 | head -5
  echo "== 与最近备份的差异（前 60 行）=="
  B=$(ls -t "$F".bak-* 2>/dev/null | head -1)
  echo "backup=$B"
  [ -n "$B" ] && diff -u "$B" "$F" 2>&1 | head -60 | cut -c1-180
  echo "== 近期该目录的跑测日志 =="
  ls -lt /home/huawei_ts_program/litehost_perf_opt/vllmBench 2>/dev/null | head -5
  ls -lt /home/s00806700/vllmBench 2>/dev/null | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
