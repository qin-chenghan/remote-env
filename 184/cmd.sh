#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：查 should_profile_instance 的出处与调用点。
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
  echo "== occurrences =="
  grep -rn 'should_profile_instance' /home/qch/scripts /home/huawei_ts_program /home/qch/tools \
    /opt/corex311/lib/python3.11/site-packages/vllm 2>/dev/null | head -12

  echo "== PROFILE_EVERY =="
  grep -rn 'PROFILE_EVERY' /home/qch/scripts 2>/dev/null | head -10

  echo "== call sites with context =="
  for f in $(grep -rl 'should_profile_instance' /home/qch/scripts 2>/dev/null | head -4); do
    echo "-- $f --"
    grep -n -B4 -A8 'should_profile_instance' "$f" | head -40 | cut -c1-160
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
