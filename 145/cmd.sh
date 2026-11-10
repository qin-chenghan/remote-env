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
  echo "== 1. Makefile =="
  docker exec fusionv1 cat /home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/Makefile 2>&1 | head -70

  echo "== 2. NEON 代码在哪个文件 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
for f in fusion_func_v2.cpp fusion_func.cpp opt_func_v2.cpp opt_func.cpp; do
  printf "%-18s x16=%s norm=%s vqmovun=%s lines=%s\n" "$f" \
    "$(grep -c clip_u8_i32_x16 "$P/$f" 2>/dev/null)" \
    "$(grep -c clip_norm_x16 "$P/$f" 2>/dev/null)" \
    "$(grep -c vqmovun_s32 "$P/$f" 2>/dev/null)" \
    "$(wc -l < "$P/$f" 2>/dev/null)"
done
' 2>&1 | head -20

  echo "== 3. 与备份目录对比 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
B=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro-backup
echo "-- backup dir --"; ls -la "$B" 2>&1 | head -15
echo "-- diff fusion_func_v2.cpp --"
diff -u "$B/fusion_func_v2.cpp" "$P/fusion_func_v2.cpp" 2>&1 | head -70
echo "-- diff 行数 --"
diff "$B/fusion_func_v2.cpp" "$P/fusion_func_v2.cpp" 2>/dev/null | wc -l
' 2>&1 | head -100

  echo "== 4. benchmark.md =="
  docker exec fusionv1 cat /home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/benchmark.md 2>&1 | head -120

  echo "== 5. 测试程序参数 =="
  docker exec fusionv1 bash -lc '
cd /home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
strings fusion.unittest 2>/dev/null | grep -iE "usage|thread|step|resize|width|height" | head -15
' 2>&1 | head -20

  echo "== 6. 两个二进制 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
ls -l "$P/fusion.unittest" "$P/fusion.unittest.bak_before_neon"
file "$P/fusion.unittest" "$P/fusion.unittest.bak_before_neon"
' 2>&1 | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
