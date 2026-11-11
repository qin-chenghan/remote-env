#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：定位当前压测 run 目录、进度与每 case 耗时。
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
  S=$(pgrep -f 'vllmBench_lite_opt.sh' 2>/dev/null | head -1)
  echo "script_pid=$S"
  CWD=$(readlink "/proc/$S/cwd" 2>/dev/null)
  echo "script_cwd=$CWD"
  echo "started=$(ps -o lstart= -p "$S" 2>/dev/null)  elapsed=$(ps -o etime= -p "$S" 2>/dev/null)"

  echo "== its env =="
  tr '\0' '\n' < "/proc/$S/environ" 2>/dev/null | grep -E 'TEST_ID|PREFIX|NUM_PROMPTS|NUM_WARMUPS|MAX_CONCURRENCY|GPU_LIST|HOST_MEASURE|COMPILATION' | head -12

  echo "== run dirs =="
  ls -lt "$CWD/vllmBench" 2>&1 | head -6
  R=$(ls -dt "$CWD"/vllmBench/*/ 2>/dev/null | head -1)
  echo "RUN=$R"

  echo "== run contents =="
  ls -la "$R" 2>&1 | head -20
  echo "-- summary.csv --"
  cat "$R/summary.csv" 2>&1 | head -15
  echo "-- logs dir --"
  ls -lt "$R/logs" 2>&1 | head -10
  echo "-- server.log tail --"
  tail -6 "$R/logs/server.log" 2>&1

  echo "== case timing (dir mtimes) =="
  for d in "$R"/*/; do
    [ -d "$d" ] || continue
    printf '%s  %s\n' "$(stat -c %y "$d" 2>/dev/null | cut -d. -f1)" "$(basename "$d")"
  done | sort | head -20

  echo "== bench_driver now =="
  for p in $(pgrep -f 'bench_driver.py' 2>/dev/null); do
    echo "pid=$p started=$(ps -o lstart= -p $p) elapsed=$(ps -o etime= -p $p)"
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -oE '--random_input_len [0-9]+|--random_output_len [0-9]+|--num_prompts [0-9]+' | tr '\n' ' '; echo
  done

  echo "== session/litehost progress =="
  ls -lt "$R"/litehost 2>&1 | head -10
  find "$R" -maxdepth 3 -name 'session.json' -o -maxdepth 3 -name '*.csv' 2>/dev/null | head -10

  echo "== gpu =="
  ixsmi 2>&1 | sed -n '5,20p'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
