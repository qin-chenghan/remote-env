#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。检视 libkperf 的真实接口，以及测试人员在 vllm 容器里最终怎么改的。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

LK=/home/l00946765/workspace/performance-tools/libkperf
F=/opt/corex311/lib/python3.11/site-packages/vllm/v1/executor/multiproc_executor.py

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. libkperf 目录 =="
  ls -lat "$LK" 2>/dev/null | head -15
  ls -l "$LK"/*.so "$LK"/*.py 2>/dev/null | head -8

  echo "== 2. kperf_start_type 的真实定义 =="
  grep -n "def kperf_start_type\|def start_type\|ctypes\|CDLL\|import " "$LK/libkperf.py" 2>/dev/null | head -20
  echo "-- 定义体 --"
  awk '/def kperf_start_type/,/^def [a-zA-Z_]+\(/ {print NR": "$0}' "$LK/libkperf.py" 2>/dev/null | head -20

  echo "== 3. 测试人员改后的 vllm 文件（头部与调用处）=="
  docker exec vllm bash -lc "grep -n 'kperf' $F" 2>&1
  docker exec vllm bash -lc "sed -n '1,45p' $F | grep -nE 'import|kperf'" 2>&1 | head -20
  docker exec vllm bash -lc "sed -n '970,992p' $F" 2>&1

  echo "== 4. 容器内 kperf 是否可用 / 放在哪 =="
  docker exec vllm bash -lc '
    /opt/corex311/bin/python3 -c "import kperf; print(kperf.__file__); print([n for n in dir(kperf) if \"start\" in n or \"type\" in n])" 2>&1 | tail -4
    /opt/corex311/bin/python3 -c "from kperf import kperf_start_type; print(kperf_start_type)" 2>&1 | tail -3
    ls /opt/corex311/lib/python3.11/site-packages/kperf* /home/*/libkperf* 2>/dev/null | head -6
  ' 2>&1 | head -14

  echo "== 5. 备份文件是否存在（他们是否留了回滚点）=="
  docker exec vllm bash -lc "ls -l $F.bak* 2>/dev/null | head -5" 2>&1

  echo "== 6. 当前那次 run 是否已正常产出 =="
  docker ps --filter name=vllm --format '{{.Names}} {{.Status}}'
  ls -lt /home/huawei_ts_program/litehost_perf_opt/vllmBench 2>/dev/null | head -3

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
