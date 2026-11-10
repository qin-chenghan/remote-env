#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
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
  # 只读：查看 203 上现用的基线脚本及其依赖。

  D=/home/qch/scripts/litehost_perf

  echo "== 1. 目录 =="
  ls -la "$D" 2>&1 | head -30

  echo "== 2. vllmBench_lite_taskset.sh 全文 =="
  if [ -f "$D/vllmBench_lite_taskset.sh" ]; then
    wc -l "$D/vllmBench_lite_taskset.sh"
    cat -n "$D/vllmBench_lite_taskset.sh"
  else
    echo "!! 不存在 $D/vllmBench_lite_taskset.sh"
    find /home/qch -maxdepth 4 -name 'vllmBench*' 2>/dev/null | head -10
  fi

  echo "== 3. 同目录其他脚本 =="
  ls "$D"/*.sh "$D"/*.py 2>/dev/null | head -20

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
