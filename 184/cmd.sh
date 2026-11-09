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
  # 只读对比：litehost_perf.zip 里的原始 vllmBench_lite.sh vs 184 的 base 脚本。

  Z=/home/qch/transfer/litehost_perf.zip
  B=/home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base.sh
  O=/home/qch/scripts/vllmBench_lite.sh

  echo "== 1. zip 信息 =="
  ls -la "$Z" 2>/dev/null || echo "zip missing"
  unzip -l "$Z" 2>/dev/null | head -30

  ENTRY=$(unzip -Z1 "$Z" 2>/dev/null | grep -E "vllmBench_lite.sh$" | head -1)
  echo "ENTRY=$ENTRY"

  echo "== 2. 原始脚本头部（前 80 行）=="
  unzip -p "$Z" "$ENTRY" 2>/dev/null | sed -n '1,80p'

  echo "== 3. 原始 vs 184 base（完整 diff）=="
  diff -u <(unzip -p "$Z" "$ENTRY" 2>/dev/null) "$B" | head -300

  echo "== 4. 原始 vs /home/qch/scripts/vllmBench_lite.sh =="
  diff -u <(unzip -p "$Z" "$ENTRY" 2>/dev/null) "$O" 2>/dev/null | head -80

  echo "== 5. 关键段对照 =="
  echo "-- 原始 SERVER_EXTRA_ENV / SERVER_ARGS --"
  unzip -p "$Z" "$ENTRY" 2>/dev/null | grep -nE "SERVER_EXTRA_ENV|SERVER_ARGS|UMD_MAXCOMMAND|VLLM_|PREFIX=" -A4 | head -60
  echo "-- base 同段 --"
  grep -nE "SERVER_EXTRA_ENV|SERVER_ARGS|UMD_MAXCOMMAND|VLLM_|PREFIX=" "$B" -A4 | head -60

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
