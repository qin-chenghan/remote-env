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
  # 只读：定位 clamp_to_u8 的定义与所有调用点，以及所在循环。

  echo "== 1. clamp_to_u8 出现在哪些文件 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
grep -rn "clamp_to_u8" "$P" --include="*.cpp" --include="*.h" 2>/dev/null | head -20
' 2>&1 | head -25

  echo "== 2. kUint8ToFloatDivisor 定义 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
grep -rn "kUint8ToFloatDivisor" "$P" --include="*.cpp" --include="*.h" 2>/dev/null | head -10
' 2>&1 | head -15

  echo "== 3. 定义与上下文 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
F=$(grep -rln "static inline uint8_t clamp_to_u8" "$P" --include="*.cpp" --include="*.h" 2>/dev/null | head -1)
echo "F=$F"
[ -n "$F" ] && grep -n -B8 -A20 "clamp_to_u8" "$F" | head -70
' 2>&1 | head -80

  echo "== 4. 调用点所在函数 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
for f in $(grep -rl "clamp_to_u8(" "$P" --include="*.cpp" 2>/dev/null); do
  echo "--- $(basename $f) ---"
  grep -n "^[a-zA-Z_].*(" "$f" | head -20
done
' 2>&1 | head -40

  echo "== 5. 该文件是否参与构建 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
grep -n "\.o" "$P/Makefile" | head -25
' 2>&1 | head -30

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
