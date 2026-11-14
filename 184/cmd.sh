#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 定位 H/S 分歧：trace 侧把 S 拆主线程/其它线程 + sync 次数，与 litehost 报告对表。
# 纯 CPU、绑 node0、不启动任何服务。
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
  T=/home/qch/scripts/timeline
  PY="$DIR/trace_tshg_split.py"
  BIND="numactl --cpunodebind=0 --membind=0"
  command -v numactl >/dev/null || BIND="taskset -c $(lscpu -e=CPU,NODE | awk '$2==0{print $1}' | paste -sd,)"

  pick() {
    local f
    f=$(find "$T/$1" -type f \( -name '*trace*.json' -o -name '*trace*.json.gz' \) -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    [ -n "$f" ] || f=$(find "$T/$1" -type f \( -name '*.json' -o -name '*.json.gz' \) -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    echo "$f"
  }

  echo "== 1. trace 侧：主线程/其它线程 S 拆分 =="
  for pair in "4k 64k" "4k2 64k2"; do
    set -- $pair; A=$1; B=$2
    FA=$(pick "$A"); FB=$(pick "$B")
    echo "===== $A vs $B"
    echo "A=$FA"
    echo "B=$FB"
    if [ -z "${FA:-}" ] || [ -z "${FB:-}" ]; then echo "缺 trace，跳过"; continue; fi
    TSHG_WARMUP=0 timeout 900 $BIND python3 "$PY" "$FA" "$FB" "$A" "$B" 2>&1 | tail -70
  done

  echo "== 2. litehost 侧：找 bench 报告 =="
  for r in /home/huawei_ts_program/litehost_perf_opt/vllmBench/4k \
           /home/huawei_ts_program/litehost_perf_opt/vllmBench/64k \
           /home/z30059427/vllmBench/litehost_gap_20261109_195202 \
           /usr/local/corex-5.0.0/vllmBench/litehost_gap_20261110_164715; do
    echo "---- $r"
    [ -d "$r" ] || { echo "(不存在)"; continue; }
    find "$r" -maxdepth 4 \( -name 'per_rank.csv' -o -name 'four_rank_totals.csv' \) 2>/dev/null | head -5
    for f in $(find "$r" -maxdepth 4 -name 'per_rank.csv' 2>/dev/null | head -2); do
      echo "  ## $f"
      head -1 "$f"
      grep -m2 'in128_out128' "$f"
    done
    for f in $(find "$r" -maxdepth 4 -name 'four_rank_totals.csv' 2>/dev/null | head -2); do
      echo "  ## $f"
      head -1 "$f"
      grep -m2 'in128_out128' "$f"
    done
  done

  echo "== 3. litehost 侧：rank 行（含 sync_calls）=="
  for r in /home/huawei_ts_program/litehost_perf_opt/vllmBench/4k \
           /home/huawei_ts_program/litehost_perf_opt/vllmBench/64k \
           /home/z30059427/vllmBench/litehost_gap_20261109_195202 \
           /usr/local/corex-5.0.0/vllmBench/litehost_gap_20261110_164715; do
    [ -d "$r" ] || continue
    echo "---- $r"
    grep -rh "rank[0-3] pid=.*formal=" "$r" 2>/dev/null | head -4
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
