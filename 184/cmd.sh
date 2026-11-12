#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 定位 2026-11-09 采的两份 9-case run（4K / 64K），用 in128_out128 的 H+G 4.299 / 3.646 匹配。
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

  echo "== 1. 该根目录下所有 run =="
  dex "ls -lat --time-style=long-iso /usr/local/corex-5.0.0/vllmBench/ | head -40"

  echo "== 2. 所有 1109 的 run，逐个看 case 数与 in128_out128 的 H+G =="
  for d in $(timeout 60 docker exec "$C" bash -c "ls -d /usr/local/corex-5.0.0/vllmBench/litehost_gap_20261109_* 2>/dev/null"); do
    echo "---- $d"
    echo -n "  started: "; dex "grep -m1 '^started=' $d/config.txt 2>/dev/null"
    echo -n "  cases:   "; dex "ls $d/bs8_*.json 2>/dev/null | wc -l"
    echo -n "  has summary/host_summary: "; dex "ls -d $d/summary.csv $d/host_summary 2>/dev/null | tr '\n' ' '; echo"
    echo "  in128_out128 H+G:"
    dex "grep -h ',all_formal,' $d/host_summary/four_rank_totals.csv 2>/dev/null | awk -F, '\$1==\"bs8_in128_out128\"{print \"    \"\$11}'"
    dex "grep -h ',all_formal,' $d/litehost/bs8_in128_out128/host_report/four_rank_totals.csv 2>/dev/null | awk -F, '{print \"    per-case \"\$11}'"
    echo "  config:"
    dex "sed -n '1,12p' $d/config.txt 2>/dev/null | sed 's/^/    /'"
  done

  echo "== 3. 全根目录扫描：找 H+G 匹配 4.299 / 3.646 的 all_formal 行 =="
  for f in $(timeout 120 docker exec "$C" bash -c "ls /usr/local/corex-5.0.0/vllmBench/litehost_gap_*/host_summary/four_rank_totals.csv 2>/dev/null"); do
    hit=$(timeout 60 docker exec "$C" bash -c "awk -F, '\$1==\"bs8_in128_out128\" && \$3==\"all_formal\"{print \$11}' $f")
    [ -n "$hit" ] && echo "$f  in128_out128 H+G=$hit"
  done

  echo "== 4. 内核版本线索（4K vs 64K 应该写在某个 meta/日志里）=="
  for d in $(timeout 60 docker exec "$C" bash -c "ls -d /usr/local/corex-5.0.0/vllmBench/litehost_gap_20261109_* 2>/dev/null"); do
    echo "---- $d"
    dex "grep -rhiE 'uname|kernel|64K|4K|PAGESIZE' $d/config.txt $d/*.meta.json $d/logs/preflight.log 2>/dev/null | head -5"
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
