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
  echo "== 1. 完整目录（不截断）=="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
ls -la "$P"
' 2>&1 | head -80

  echo "== 2. 所有源文件（cpp/h）=="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
ls -l "$P"/*.cpp "$P"/*.h 2>/dev/null
' 2>&1 | head -30

  echo "== 3. NEON 符号在各源文件中的分布 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
for f in "$P"/*.cpp; do
  printf "%-45s x16=%s norm=%s vqmovun=%s lines=%s\n" "$(basename "$f")" \
    "$(grep -c clip_u8_i32_x16 "$f" 2>/dev/null)" \
    "$(grep -c clip_norm_x16 "$f" 2>/dev/null)" \
    "$(grep -c vqmovun_s32 "$f" 2>/dev/null)" \
    "$(wc -l < "$f" 2>/dev/null)"
done
' 2>&1 | head -20

  echo "== 4. pillow_opt_func_v2.cpp 概况与 NEON 段 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
F=$P/pillow_opt_func_v2.cpp
ls -l "$F" 2>&1
[ -f "$F" ] && { wc -l "$F"; grep -n "clip_u8_i32_x16\|clip_norm_x16\|vqmovun_s32\|clip_u8_i32" "$F" | head -20; }
' 2>&1 | head -30

  echo "== 5. Makefile =="
  docker exec fusionv1 cat /home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/Makefile 2>&1 | head -70

  echo "== 6. benchmark.md =="
  docker exec fusionv1 cat /home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/benchmark.md 2>&1 | head -120

  echo "== 7. 备份目录与当前目录对比 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
B=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro-backup
echo "-- backup --"; ls -l "$B" 2>&1 | head -20
echo "-- diff pillow_opt_func_v2.cpp --"
diff -u "$B/pillow_opt_func_v2.cpp" "$P/pillow_opt_func_v2.cpp" 2>&1 | head -60
echo "-- diff 行数 --"
diff "$B/pillow_opt_func_v2.cpp" "$P/pillow_opt_func_v2.cpp" 2>/dev/null | wc -l
' 2>&1 | head -90

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
