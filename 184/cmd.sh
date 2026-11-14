#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：四份 run 的 128/128 吞吐与 TSHG 并排（变量全部在容器内展开）。
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
  dex() { timeout 120 docker exec "$C" bash -c "$1"; }

  echo "== 1+2. 四份 run 的 128/128：吞吐行、TSHG 行、完整性 =="
  dex 'R=/usr/local/corex-5.0.0/vllmBench
for r in 150257 101902 164759 094606; do
  d=$(ls -d $R/litehost_gap_*_${r} 2>/dev/null | head -1)
  echo "===== ${r}  ${d}"
  echo "--- summary header ---"; head -1 $d/summary.csv | cut -d, -f1-7
  echo "--- summary 128/128 ---"; grep -h bs8_in128_out128, $d/summary.csv
  echo "--- TSHG 128/128 ---"; grep -h bs8_in128_out128, $d/host_summary/four_rank_totals.csv 2>/dev/null
  n=$(ls -d $d/litehost/*/ 2>/dev/null | wc -l)
  ok=$(grep -l "status": "complete" $d/litehost/*/window.json 2>/dev/null | wc -l)
  echo "case_dirs=$n complete_windows=$ok"
done'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
