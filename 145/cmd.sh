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
  echo "== 1. 备份源码 vs 当前源码（完整 diff）=="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
diff -u "$P/pillow_fusion_func_v2.cpp.bak_clip_neon" "$P/pillow_fusion_func_v2.cpp"
echo "-- diff 行数 --"
diff "$P/pillow_fusion_func_v2.cpp.bak_clip_neon" "$P/pillow_fusion_func_v2.cpp" | wc -l
' 2>&1 | head -120

  echo "== 2. 测试程序测量了哪些函数 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
grep -n "opt_func\|fusion_func\|pillow_opt\|pillow_fusion\|benchmark\|printf" "$P/fusion_test.cpp" | head -40
' 2>&1 | head -45

  echo "== 2b. 四个 pillow 变体都导出了什么函数 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
for f in pillow_opt_func.cpp pillow_opt_func_v2.cpp pillow_fusion_func.cpp pillow_fusion_func_v2.cpp; do
  echo "--- $f ---"
  grep -nE "^[a-zA-Z_][a-zA-Z0-9_ *]*\(" "$P/$f" | grep -v "static inline" | head -12
done
' 2>&1 | head -60

  echo "== 2c. 测试程序实际引用了哪些 pillow 符号 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
echo "-- fusion_test.o 未定义符号 --"
nm -u "$P/fusion_test.o" 2>/dev/null | grep -i pillow | head -20
echo "-- 最终二进制里的 pillow 符号 --"
nm -C "$P/fusion.unittest" 2>/dev/null | grep -i "pillow" | grep -E " T | t " | head -20
' 2>&1 | head -50

  echo "== 3. 结果打印格式 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
grep -n "printf\|cout\|Step" "$P/fusion_test.cpp" | sed -n "1,60p"
' 2>&1 | head -60

  echo "== 4. run_fusion.sh =="
  docker exec fusionv1 cat /home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/run_fusion.sh 2>&1 | head -30

  echo "== 5. main 函数结构 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
awk "/int main|^main/,0" "$P/fusion_test.cpp" | head -70
' 2>&1 | head -80

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
