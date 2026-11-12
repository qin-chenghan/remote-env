#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 跨根目录找 1109 的 run（4K 基线），并列出所有 run 的 in128_out128 H+G。
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
  dex() { timeout 180 docker exec "$C" bash -c "$1"; }

  echo "== 1. 全盘找 litehost_gap_20261109_* 目录 =="
  dex "find /home /usr/local /data /opt -maxdepth 7 -type d -name 'litehost_gap_20261109_*' 2>/dev/null"

  echo "== 2. 全盘找所有 run 的 host_summary，列出 in128_out128 的 H+G =="
  dex "for f in \$(find /home /usr/local -maxdepth 8 -path '*/host_summary/four_rank_totals.csv' 2>/dev/null); do \
         v=\$(awk -F, '\$1==\"bs8_in128_out128\" && \$3==\"all_formal\"{print \$11}' \"\$f\"); \
         [ -n \"\$v\" ] && echo \"\$v  \$f\"; \
       done | sort -n"

  echo "== 3. 精确匹配 4.29x 与 3.64x =="
  dex "for f in \$(find /home /usr/local -maxdepth 8 -path '*/host_summary/four_rank_totals.csv' 2>/dev/null); do \
         awk -F, -v f=\"\$f\" '\$1==\"bs8_in128_out128\" && \$3==\"all_formal\" && (\$11 ~ /^4\.29/ || \$11 ~ /^3\.64/) {print f, \$11}' \"\$f\"; \
       done"

  echo "== 4. 候选目录的 9 个 case 与时间 =="
  for d in /usr/local/corex-5.0.0/vllmBench/litehost_gap_20261110_164715; do
    echo "---- $d"
    dex "ls -1 $d/bs8_*.json 2>/dev/null | xargs -n1 basename"
    dex "grep -m1 '^started=' $d/config.txt; sed -n '1,12p' $d/config.txt"
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
