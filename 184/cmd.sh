#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 直接进 corex5-py311 容器检查 /usr/local/corex-5.0.0/vllmBench/litehost_gap_20261112_150257
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
  PB=/usr/local/corex-5.0.0/vllmBench

  echo "== 1. 容器状态 =="
  docker ps -a --filter "name=$C" --format '{{.ID}}  {{.Names}}  {{.Image}}  {{.Status}}'
  docker exec "$C" echo alive || { echo "容器不可 exec，结束"; exit 3; }

  echo "== 2. vllmBench 下所有 run 目录 =="
  docker exec "$C" bash -c "ls -lat $PB | head -20"

  echo "== 3. 目标目录 =="
  docker exec "$C" bash -c "ls -ld $P; du -sh $P 2>/dev/null"

  echo "== 4. 文件清单 =="
  docker exec "$C" bash -c "cd $P && find . -type f -printf '%10s  %TY-%Tm-%Td %TH:%TM  %p\n' | sort -k4 | head -60"
  docker exec "$C" bash -c "echo 文件数: \$(find $P -type f | wc -l)"

  echo "== 5. config.txt =="
  docker exec "$C" bash -c "head -40 $P/config.txt 2>&1"

  echo "== 6. summary.csv =="
  docker exec "$C" bash -c "head -20 $P/summary.csv 2>&1"

  echo "== 7. host_summary =="
  docker exec "$C" bash -c "ls -la $P/host_summary 2>&1"
  docker exec "$C" bash -c "head -40 $P/host_summary/report.txt 2>&1"
  echo "-- four_rank_totals.csv --"
  docker exec "$C" bash -c "head -10 $P/host_summary/four_rank_totals.csv 2>&1"

  echo "== 8. 日志尾部 =="
  docker exec "$C" bash -c "ls -la $P/logs 2>&1"
  docker exec "$C" bash -c "tail -20 $P/logs/bench_*.log 2>&1"

  echo "== 9. 与 145924 对比 =="
  R=/home/s00806700/litehost_perf_opt/vllmBench/litehost_gap_20261112_145924
  docker exec "$C" bash -c "test -d $R && echo '145924 可见' || echo '145924 容器内不可见'"
  docker exec "$C" bash -c "test -d $R && find $R -type f | wc -l"
  echo "-- 两边顶层差异 --"
  docker exec "$C" bash -c "diff <(cd $R && find . -maxdepth 2 | sort) <(cd $P && find . -maxdepth 2 | sort) 2>&1 | head -40"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
