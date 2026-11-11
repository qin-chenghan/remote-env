#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：查谁在跑 vLLM、用的哪份脚本、进度与预计剩余时间。
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
  echo "== who is logged in =="
  who 2>&1 | head -6

  echo "== vllm processes =="
  ps -eo pid,user,ppid,lstart,etime,args 2>/dev/null \
    | grep -E 'vllm.entrypoints|bench_driver|lhctl|vllmBench' | grep -v grep | cut -c1-210 | head -12

  echo "== process ancestry for the server =="
  P=$(pgrep -f 'vllm.entrypoints.openai.api_server' 2>/dev/null | head -1)
  echo "server_pid=$P"
  if [ -n "$P" ]; then
    echo "  cwd=$(readlink /proc/$P/cwd 2>&1)"
    A=$P
    for i in 1 2 3 4 5 6; do
      A=$(awk '{print $4}' "/proc/$A/stat" 2>/dev/null)
      [ -z "$A" ] && break
      [ "$A" = "0" ] && break
      echo "  ppid=$A $(ps -o user=,args= -p "$A" 2>/dev/null | cut -c1-180)"
    done
  fi

  echo "== bench runs on disk =="
  for d in /home/*/vllmBench /home/*/*/vllmBench /home/huawei_ts_program/litehost_perf_opt/vllmBench; do
    [ -d "$d" ] || continue
    ls -lt "$d" 2>/dev/null | head -4
  done

  echo "== newest run dir contents =="
  R=$(ls -dt /home/*/vllmBench/*/ /home/huawei_ts_program/litehost_perf_opt/vllmBench/*/ 2>/dev/null | head -1)
  echo "RUN=$R"
  if [ -n "$R" ] && [ -d "$R" ]; then
    ls -la "$R" 2>&1 | head -15
    echo "-- summary.csv --"
    cat "$R/summary.csv" 2>&1 | head -15
    echo "-- server.log tail --"
    tail -5 "$R/logs/server.log" 2>&1
    echo "-- case dirs --"
    ls -d "$R"/case_* "$R"/litehost* 2>/dev/null | head -12
  fi

  echo "== script knobs =="
  for S in $(ls -t /home/*/*/vllmBench_lite*.sh /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite*.sh 2>/dev/null | head -2); do
    echo "-- $S (mtime $(stat -c %y "$S" | cut -d. -f1))"
    grep -nE 'NUM_PROMPTS=|NUM_WARMUPS=|MAX_CONCURRENCY=|CASE_INTERVAL=|CASES=\(|^ *"[0-9]+ [0-9]+"' "$S" 2>/dev/null | head -20
  done

  echo "== bench driver args =="
  pgrep -af 'bench_driver' 2>/dev/null | cut -c1-220 | head -3

  echo "== gpu load =="
  ixsmi 2>&1 | sed -n '5,20p'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
