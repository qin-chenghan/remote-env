#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：把四份完整 run 的 128/128 case 的吞吐与 TSHG 并排。
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
  R=/usr/local/corex-5.0.0/vllmBench
  dex() { timeout 120 docker exec "$C" bash -c "$1"; }

  echo "== 1. 四份 run 的 128/128 吞吐行 =="
  dex "for r in 150257 101902 164759 094606; do
      d=\$(ls -d $R/litehost_gap_2026111?_${r} $R/litehost_gap_20261114_${r} 2>/dev/null | head -1)
      echo \"===== \$d\"
      head -1 \$d/summary.csv | cut -d, -f1-3,4-7
      grep -h 'bs8_in128_out128,' \$d/summary.csv
    done"

  echo "== 2. 四份 run 的 128/128 TSHG（all_formal）=="
  dex "for r in 150257 101902 164759 094606; do
      d=\$(ls -d $R/litehost_gap_2026111?_${r} $R/litehost_gap_20261114_${r} 2>/dev/null | head -1)
      echo \"===== \$d\"
      grep -h 'bs8_in128_out128,' \$d/host_summary/four_rank_totals.csv 2>/dev/null
    done"

  echo "== 3. 每份 run 的 case 完整性 =="
  dex "for r in 150257 101902 164759 094606; do
      d=\$(ls -d $R/litehost_gap_2026111?_${r} $R/litehost_gap_20261114_${r} 2>/dev/null | head -1)
      n=\$(ls -d \$d/litehost/*/ 2>/dev/null | wc -l)
      ok=\$(python3 -c \"import json,glob,os;print(sum(1 for w in glob.glob('\$d/litehost/*/window.json') if json.load(open(w)).get('status')=='complete'))\" 2>/dev/null)
      echo \"\$(basename \$d)  case目录=\$n  完成window=\$ok\"
    done"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
