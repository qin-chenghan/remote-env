#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读 + 导出：定位正在跑的 vllmBench run，打印并在仓库里导出小结果文件。
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
  echo "== 正在跑的 bench =="
  pgrep -af 'vllmBench_lite|bench_driver|lhctl' 2>/dev/null | cut -c1-200 | head -10

  P=$(pgrep -af 'vllmBench_lite' 2>/dev/null | grep -v cmd.sh | awk '{print $1}' | head -1)
  echo "main_pid=$P"
  if [ -n "$P" ]; then
    echo "cwd=$(readlink /proc/$P/cwd 2>/dev/null)"
    echo "--- env ---"
    tr '\0' '\n' < "/proc/$P/environ" 2>/dev/null | grep -E '^TEST_ID=|^CPU_RANGE=|^PREFIX=|^MODEL_PATH=|^NUM_PROMPTS=|^HOST_MEASURE=|^CASE_INTERVAL=' | head -10
    CWD=$(readlink /proc/$P/cwd 2>/dev/null)
  else
    CWD=""
  fi

  echo "== 候选 run 目录 =="
  for base in "$CWD" /home/huawei_ts_program/litehost_perf_opt /home/s00806700/litehost_perf_opt /home/s00806700/litehost_perf; do
    [ -n "$base" ] && [ -d "$base/vllmBench" ] && ls -lt "$base/vllmBench" 2>/dev/null | head -3
  done

  RUN=$(ls -dt "$CWD"/vllmBench/*/ 2>/dev/null | head -1)
  [ -n "$RUN" ] || RUN=$(ls -dt /home/*/vllmBench/*/ /home/*/*/vllmBench/*/ 2>/dev/null | head -1)
  echo "RUN=$RUN"
  if [ -n "$RUN" ] && [ -d "$RUN" ]; then
    echo "-- 目录 --"; ls -la "$RUN" 2>&1 | head -15
    echo "-- summary.csv --"; head -20 "$RUN/summary.csv" 2>&1
    echo "-- config.txt --"; cat "$RUN/config.txt" 2>&1 | head -20
    echo "-- host_summary --"; ls "$RUN/host_summary" 2>&1 | head
    for f in "$RUN"/host_summary/*.csv; do [ -f "$f" ] && { echo "-- $(basename "$f") --"; head -12 "$f"; }; done
    echo "-- logs --"; ls -lt "$RUN/logs" 2>&1 | head -8

    echo "== 导出小结果到仓库 =="
    NAME=$(basename "$RUN")
    EX="$DIR/export/$NAME"
    mkdir -p "$EX"
    for f in summary.csv config.txt; do [ -f "$RUN/$f" ] && cp -a "$RUN/$f" "$EX/"; done
    [ -d "$RUN/host_summary" ] && cp -a "$RUN/host_summary" "$EX/" 2>/dev/null
    [ -f "$RUN/logs/server.log" ] && tail -c 200000 "$RUN/logs/server.log" > "$EX/server.tail.log"
    ls -lr "$EX" 2>&1 | head -20
    du -sh "$EX" 2>&1
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
