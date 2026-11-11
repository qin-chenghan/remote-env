#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：定位 timeline_base.sh 里 profiling 关闭的原因。
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
  F=/home/qch/scripts/timeline_base.sh

  echo "== profile 相关行（全文定位）=="
  grep -nE 'BENCH_PROFILE_ARGS|profile_state|--profile|should_profile_instance|stop_profile|start_profile' "$F" 2>&1 | cut -c1-180

  echo ""
  echo "== bench 调用段（190-300 行）=="
  sed -n '190,300p' "$F" 2>&1 | cut -c1-180

  echo ""
  echo "== bench 实际命令行 =="
  grep -nE 'bench_driver|vllm bench|bench serve|bench_instance' "$F" 2>&1 | cut -c1-180 | head -12

  echo ""
  echo "== bench 日志里的 Namespace（确认参数）=="
  head -3 /home/qch/scripts/timeline/4k/logs/bench_instance0.log 2>&1 | cut -c1-300

  echo ""
  echo "== 有没有对应的 opt 版本脚本 =="
  ls -l /home/qch/scripts/timeline*.sh 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
