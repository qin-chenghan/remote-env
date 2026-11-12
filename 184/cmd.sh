#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 导出 150257 这次 9-case 的原始结果，用于在本地补出缺失的汇总。
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
  C=corex5-py311
  P=/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261112_150257
  dex() { timeout 60 docker exec "$C" bash -c "$1"; }

  echo "== config =="
  dex "cat $P/config.txt"

  for case_id in bs8_in128_out128 bs8_in128_out1024 bs8_in128_out2048 \
                 bs8_in1024_out128 bs8_in1024_out1024 bs8_in1024_out2048 \
                 bs8_in2048_out128 bs8_in2048_out1024 bs8_in2048_out2048; do
    echo "########## CASE $case_id"
    echo "--- json ---"
    dex "cat $P/$case_id.json"
    echo
    echo "--- four_rank_totals ---"
    dex "cat $P/litehost/$case_id/host_report/four_rank_totals.csv"
    echo "--- per_rank ---"
    dex "cat $P/litehost/$case_id/host_report/per_rank.csv"
    echo
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
