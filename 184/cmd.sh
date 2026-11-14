#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：取 timeline_opt.sh 全文及其环境处理，与 bench 脚本对照。
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
  echo "== 1. timeline_opt.sh 在哪里 =="
  find /home -maxdepth 5 -name 'timeline_opt.sh' 2>/dev/null | head -10

  echo "== 2. 全文 =="
  for f in $(find /home -maxdepth 5 -name 'timeline_opt.sh' 2>/dev/null | head -2); do
    echo "---- $f"; ls -l --time-style=long-iso "$f"; cat "$f"
  done

  echo "== 3. 关键项 grep =="
  for f in $(find /home -maxdepth 5 -name 'timeline_opt.sh' 2>/dev/null | head -2); do
    echo "---- $f"
    grep -nE 'PYTHONPATH|PYTHONHOME|LD_PRELOAD|taskset|CPU_RANGE|PREFIX|PYTHON_BIN|compilation-config|NUM_PROMPTS|NUM_WARMUPS|MAX_CONCURRENCY|profiler|PROFILER|VLLM_' "$f"
  done

  echo "== 4. 容器默认 PYTHONPATH（bench 脚本会 unset，timeline 未必）=="
  docker exec corex5-py311 bash -c 'env | grep -E "^PYTHONPATH|^PYTHONHOME|^LD_PRELOAD" || echo 无' 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
