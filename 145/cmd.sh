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
  echo "== 1. 路径形态 =="
  docker exec fusionv1 bash -lc '
    ls -ld /home/workspace /home /workspace 2>&1
    readlink -f /home/workspace 2>&1
    echo "HOME=$HOME"; echo "PWD=$(pwd)"
    ls -la /workspace 2>&1 | head -10
  ' 2>&1 | head -25

  echo "== 2. tensor 目录 =="
  docker exec fusionv1 bash -lc '
    ls -la /home/workspace/tensor 2>&1 | head -20
    echo "-- files --"
    ls -la /home/workspace/tensor/files 2>&1 | head -30
  ' 2>&1 | head -60

  echo "== 3. 直接检查用户给的路径 =="
  docker exec fusionv1 bash -lc '
    P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
    ls -ld "$P" 2>&1
    ls -la "$P" 2>&1 | head -30
  ' 2>&1 | head -40

  echo "== 4. 全盘找 cpp（跟随符号链接）=="
  docker exec fusionv1 bash -lc '
    find -L /home /workspace -maxdepth 6 -type f -name "pillow_fusion_func_v2.cpp" 2>/dev/null | head -10
  ' 2>&1 | head -15

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
