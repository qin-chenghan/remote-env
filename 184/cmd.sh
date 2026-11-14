#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 离线重算 11-12 的 4k/64k timeline trace：纯 CPU、绑 node0、不启动任何服务。
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

  echo "== 1. 解释器 =="
  command -v python3 && python3 -V
  command -v taskset && nproc

  echo "== 2. NUMA 布局 =="
  (command -v numactl >/dev/null && numactl -H | head -6) || echo "no numactl"
  CORES=$(lscpu -e=CPU,NODE 2>/dev/null | awk '$2==0{print $1}' | paste -sd,)
  [ -n "$CORES" ] || CORES=$(seq -s, 0 $(( $(nproc) / 2 - 1 )))
  echo "node0 cores: $CORES"
  if command -v numactl >/dev/null; then BIND="numactl --cpunodebind=0 --membind=0"; else BIND="taskset -c $CORES"; fi
  echo "bind: $BIND"

  echo "== 3. 找 trace 文件 =="
  for d in 4k 64k 4k2 64k2; do
    echo "---- $d"
    find "$T/$d" -type f -size +1M -printf '%10s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort -rn | head -6
  done

  echo "== 4. 脚本 =="
  ls -l "$PY"

  pick() {  # 优先 *trace*.json*，否则退到最大的 json
    local f
    f=$(find "$T/$1" -type f \( -name '*trace*.json' -o -name '*trace*.json.gz' \) -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    [ -n "$f" ] || f=$(find "$T/$1" -type f \( -name '*.json' -o -name '*.json.gz' \) -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    echo "$f"
  }

  echo "== 5. 离线重算 =="
  for pair in "4k 64k" "4k2 64k2"; do
    set -- $pair; A=$1; B=$2
    FA=$(pick "$A")
    FB=$(pick "$B")
    echo "===== $A vs $B"
    echo "A=$FA"
    echo "B=$FB"
    if [ -z "${FA:-}" ] || [ -z "${FB:-}" ]; then echo "缺 trace，跳过"; continue; fi
    TSHG_WARMUP=0,2,16 timeout 900 $BIND python3 "$PY" "$FA" "$FB" "$A" "$B" 2>&1 | tail -60
    echo "rc=${PIPESTATUS[0]}"
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
