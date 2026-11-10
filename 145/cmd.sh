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
  # 只读：确认 make clean 的删除范围、warmup/测量循环、以及可用的切换开关。
  # 不编译、不运行二进制、不改任何文件。

  echo "== 1. Makefile 全文（含 clean 目标）=="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
cat -n "$P/Makefile"
' 2>&1 | head -120

  echo "== 2. test() 函数：warmup 与测量循环 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
sed -n "560,720p" "$P/fusion_test.cpp" | cat -n
' 2>&1 | head -180

  echo "== 3. 是否有 NEON 开关宏 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
grep -n "#if\|#ifdef\|#define" "$P/pillow_fusion_func_v2.cpp" | grep -iE "neon|simd|opt|asm|arm" | head -20
echo "-- Makefile 里的宏 --"
grep -n "D[A-Z_]*=" "$P/Makefile" | head -20
' 2>&1 | head -30

  echo "== 4. 现有产物清单（确认哪些文件会被 clean 影响）=="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
ls -l "$P"/*.o "$P"/*.S "$P"/fusion.unittest* 2>/dev/null
' 2>&1 | head -40

  echo "== 5. make 变量与实际规则（dry run，不执行）=="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
cd "$P" && make -n clean 2>&1 | head -20
' 2>&1 | head -30

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
