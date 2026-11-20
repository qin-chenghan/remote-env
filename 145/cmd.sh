#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：修 vllm:latest 镜像里那行未定义的 kperf_start_type 埋点（先备份，可回滚）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
F=/opt/corex311/lib/python3.11/site-packages/vllm/v1/executor/multiproc_executor.py
BAK="$F.bak-kperf-$(date +%Y%m%d%H%M%S)"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 修改前 =="
  docker exec "$C" bash -lc "grep -n 'kperf_start_type' $F" 2>&1
  docker exec "$C" bash -lc "sha256sum $F" 2>&1

  echo "== 2. 备份并删除该行 =="
  docker exec "$C" bash -lc "cp -a $F $BAK && sed -i '/kperf_start_type(103)/d' $F" 2>&1
  docker exec "$C" bash -lc "ls -l $BAK; echo '-- 删除后检索 --'; grep -n 'kperf_start_type' $F || echo '无残留'"

  echo "== 3. 语法校验 =="
  docker exec "$C" bash -lc "/opt/corex311/bin/python3 -m py_compile $F && echo 'py_compile OK'" 2>&1

  echo "== 4. 修改后上下文 =="
  docker exec "$C" bash -lc "sed -n '975,985p' $F" 2>&1

  echo "== 5. sha256 变化 =="
  docker exec "$C" bash -lc "sha256sum $F" 2>&1

  echo "== 6. 回滚方法（记录在日志里） =="
  echo "docker exec $C cp -a $BAK $F"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
