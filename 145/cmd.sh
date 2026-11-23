#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。确认 3.12 是否有 kperf 插桩，以及两套插桩的确切路径/行号。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
F312=/usr/local/lib/python3.12/site-packages/vllm/v1/executor/multiproc_executor.py
F311=/opt/corex311/lib/python3.11/site-packages/vllm/v1/executor/multiproc_executor.py

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 3.12 套里的 kperf 插桩 =="
  docker exec "$C" bash -lc "ls -l $F312; sha256sum $F312; grep -n 'kperf' $F312 || echo '3.12: 无 kperf'" 2>&1

  echo "== 2. 3.11 套（对照）=="
  docker exec "$C" bash -lc "ls -l $F311; sha256sum $F311; grep -n 'kperf' $F311 || echo '3.11: 无 kperf'" 2>&1

  echo "== 3. 3.12 全树搜索 kperf / 其它插桩标记 =="
  docker exec "$C" bash -lc "
    grep -rln 'kperf_start_type' /usr/local/lib/python3.12/site-packages/vllm 2>/dev/null | head -5
    grep -rln 'kperf\|hotspot_opt\|host_opt' /usr/local/lib/python3.12/site-packages/vllm/v1/executor 2>/dev/null | head -5
  " 2>&1 | head -8

  echo "== 4. libkperf.so 是否存在 =="
  docker exec "$C" bash -lc "ls -l /home2/libkperf/libkperf.so 2>&1; nm -D --defined-only /home2/libkperf/libkperf.so 2>/dev/null | grep -m2 kperf_start_type" 2>&1

  echo "== 5. 两套文件差异行数 =="
  docker exec "$C" bash -lc "diff $F312 $F311 | grep -cE '^[<>]' ; diff $F312 $F311 | grep -E '^[<>].*kperf' || echo 'diff 中无 kperf 行'" 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
