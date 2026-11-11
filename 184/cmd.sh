#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：对比 timeline on/off 的实际启动差异与用例矩阵。
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
  D=/home/qch/scripts

  echo "== on vs off 全文差异（截取）=="
  diff -u "$D/timeline_off.sh" "$D/timeline_on.sh" 2>&1 | head -80 | cut -c1-170

  echo ""
  echo "== 各脚本的用例矩阵 =="
  for f in "$D"/timeline*.sh; do
    [ -f "$f" ] || continue
    echo "-- $(basename "$f") --"
    sed -n '/^CASES=(/,/^)/p' "$f" 2>/dev/null | head -15
  done

  echo ""
  echo "== 各脚本的启动相关行 =="
  for f in "$D"/timeline*.sh; do
    [ -f "$f" ] || continue
    echo "-- $(basename "$f") --"
    grep -nE 'VLLM_|LD_PRELOAD|itr_|numa|taskset|worker-cls|compilation-config|SPAWN|ixsmi|IXSMI|REPO_ROOT|PORT=' "$f" 2>/dev/null | head -18 | cut -c1-170
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
