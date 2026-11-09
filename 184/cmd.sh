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
  # 只读：用容器 overlay UpperDir 对两个 venv 的 vllm 树做完整 diff。
  # 不改任何文件。

  CON=corex5-py311
  U=$(docker inspect "$CON" --format '{{.GraphDriver.Data.UpperDir}}')
  echo "UpperDir=$U"

  echo "== 1. UpperDir 里是否有两个 venv =="
  ls -d "$U/opt/corex311" "$U/opt/corex311-cpython-vllm" 2>&1
  ls "$U/opt/corex311/lib/python3.11/site-packages/vllm" 2>/dev/null | head -5

  echo "== 2. vllm 树完整 diff（排除 pycache）=="
  diff -rq --exclude='__pycache__' \
    "$U/opt/corex311/lib/python3.11/site-packages/vllm" \
    "$U/opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm" 2>&1 | head -80

  echo "== 3. 顶层 site-packages diff 摘要（排除 dist-info/pycache）=="
  diff -rq --exclude='*.dist-info' --exclude='__pycache__' \
    "$U/opt/corex311/lib/python3.11/site-packages" \
    "$U/opt/corex311-cpython-vllm/lib/python3.11/site-packages" 2>&1 | head -40

  echo "== 4. diff 行数统计 =="
  diff -rq --exclude='__pycache__' \
    "$U/opt/corex311/lib/python3.11/site-packages/vllm" \
    "$U/opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm" 2>/dev/null | wc -l

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
