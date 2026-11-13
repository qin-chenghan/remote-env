#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 用 101902 run 已有的 7 个有效 case 重新聚合 TSHG（summary.csv + host_summary）。不跑 GPU。
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
  V=/opt/corex311-cpython-vllm
  HT=/home/huawei_ts_program/litehost_perf_opt
  PY=$V/bin/python
  dex() { timeout 300 docker exec "$C" bash -c "$1"; }
  ENV="env -u PYTHONPATH -u PYTHONHOME -u LD_PRELOAD -u LD_AUDIT -u VLLM_TORCH_PROFILER_DIR"

  echo "== 1. 前置 =="
  dex "ls -l $HT/lhctl.py $HT/analyze_litehost.py; $PY -c 'import sys;print(sys.base_prefix)'"
  dex "ls -d $P/litehost/*/ | wc -l; for d in $P/litehost/*/; do printf '%s  ' \$(basename \$d); ls \$d | grep -c 'rank[0-9]_pid' ; done"

  echo "== 2. 备份现有 summary.csv =="
  dex "cp -a $P/summary.csv $P/summary.csv.bak-agg-$TS && ls -l $P/summary.csv*"

  echo "== 3. 重新生成 summary.csv =="
  dex "cd $P && $ENV $PY $HT/lhctl.py summary $P > $P/logs/summary_build_7case.log 2>&1; echo rc=\$?; tail -5 $P/logs/summary_build_7case.log"
  dex "cat $P/summary.csv"

  echo "== 4. 先按全目录聚合（失败的 case 缺 rank 数据，可能报错）=="
  dex "cd $P && $ENV $PY $HT/analyze_litehost.py $P/litehost --link-percent 0 --out $P/host_summary --quiet > $P/logs/analyze_7case.log 2>&1; echo rc=\$?; tail -15 $P/logs/analyze_7case.log"

  echo "== 5. 若失败，用只含有效 case 的临时目录再聚合 =="
  dex "if [ ! -f $P/host_summary/four_rank_totals.csv ]; then
      rm -rf /tmp/lh7 && mkdir -p /tmp/lh7
      for d in $P/litehost/*/; do
        n=\$(basename \$d)
        if ls \$d | grep -q 'rank0_pid'; then ln -s \$d /tmp/lh7/\$n; fi
      done
      ls /tmp/lh7
      cd $P && $ENV $PY $HT/analyze_litehost.py /tmp/lh7 --link-percent 0 --out $P/host_summary --quiet > $P/logs/analyze_7case.log 2>&1
      echo rc=\$?
      tail -15 $P/logs/analyze_7case.log
    else echo '全目录聚合已成功，无需临时目录'; fi"

  echo "== 6. 产物 =="
  dex "ls -l $P/host_summary 2>&1"
  dex "echo '--- four_rank_totals.csv ---'; cat $P/host_summary/four_rank_totals.csv 2>&1 | head -5"
  dex "echo '--- report.txt 前 40 行 ---'; head -40 $P/host_summary/report.txt 2>&1"
  dex "echo '--- per_rank.csv 前 3 行 ---'; head -3 $P/host_summary/per_rank.csv 2>&1"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
