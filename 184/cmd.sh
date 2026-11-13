#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 把 7-case 聚合结果落到 run 目录，并整理成表。不跑 GPU。
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
  P=/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261113_101902
  dex() { timeout 120 docker exec "$C" bash -c "$1"; }

  echo "== 1. 落地 host_summary =="
  dex "ls -l /tmp/lh7c_out; cp -a /tmp/lh7c_out $P/host_summary && ls -l $P/host_summary"

  echo "== 2. four_rank_totals.csv 全量 =="
  dex "cat $P/host_summary/four_rank_totals.csv"

  echo "== 3. report.txt 全量 =="
  dex "cat $P/host_summary/report.txt"

  echo "== 4. 7 case 汇总（all_formal）=="
  dex "python3 - <<'PY'
import csv
rows=[r for r in csv.DictReader(open('$P/host_summary/four_rank_totals.csv')) if r['group']=='all_formal']
print(f\"{'case':22s} {'T(s)':>9s} {'S(s)':>9s} {'H(s)':>7s} {'G(s)':>7s} {'H+G(s)':>8s} {'scopes':>7s}\")
tot={k:0.0 for k in ('T','S','H','G','HG')}
for r in rows:
    t=float(r['four_rank_mean_T_total_s']); s=float(r['four_rank_mean_S_total_s'])
    h=float(r['four_rank_mean_total_H_s']); g=float(r['four_rank_mean_G_total_s'])
    hg=float(r['four_rank_mean_H_plus_G_total_s'])
    tot['T']+=t; tot['S']+=s; tot['H']+=h; tot['G']+=g; tot['HG']+=hg
    print(f\"{r['case_id']:22s} {t:9.3f} {s:9.3f} {h:7.3f} {g:7.3f} {hg:8.3f} {r['formal_scopes_per_rank']:>7s}\")
print('-'*72)
print(f\"{'SUM(7 cases)':22s} {tot['T']:9.3f} {tot['S']:9.3f} {tot['H']:7.3f} {tot['G']:7.3f} {tot['HG']:8.3f}\")
print(f'cases={len(rows)}  missing=bs8_in2048_out1024, bs8_in2048_out2048')
PY"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
