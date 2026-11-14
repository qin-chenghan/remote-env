#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：核对 4k / 4k2 / 64k / 64k2 四份 run 的配置、结果与完整性。
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
  B=/home/huawei_ts_program/litehost_perf_opt/vllmBench
  dex() { timeout 120 docker exec "$C" bash -c "$1"; }

  echo "== 0. 开机时间与运行内核（用于判断四份是否跨内核）=="
  uptime -s 2>/dev/null; uname -r; getconf PAGE_SIZE

  echo "== 1. 四份 run 的目录与 config =="
  for d in 4k 4k2 64k 64k2; do
    echo "===== $d"
    ls -l --time-style=long-iso "$B/$d" 2>&1 | head -8
    cat "$B/$d/config.txt" 2>/dev/null
  done

  echo "== 2. summary 与 TSHG =="
  dex 'B=/home/huawei_ts_program/litehost_perf_opt/vllmBench
for d in 4k 4k2 64k 64k2; do
  echo "===== $d"
  cat $B/$d/summary.csv 2>/dev/null | head -3
  echo "--- four_rank_totals ---"; cat $B/$d/host_summary/four_rank_totals.csv 2>/dev/null
done'

  echo "== 3. 完整性：case 目录 / window 状态 / 是否有错误 =="
  dex 'B=/home/huawei_ts_program/litehost_perf_opt/vllmBench
for d in 4k 4k2 64k 64k2; do
  echo "===== $d"
  ls -d $B/$d/litehost/*/ 2>/dev/null | wc -l
  grep -h "\"status\"" $B/$d/litehost/*/window.json 2>/dev/null | sort | uniq -c
  ls $B/$d/host_summary 2>/dev/null || echo 无host_summary
done'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
