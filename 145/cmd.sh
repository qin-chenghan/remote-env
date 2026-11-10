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
  # 构建两个二进制：基线（.bak_clip_neon）与优化版（当前源码），各跑一次。

  docker exec fusionv1 bash -lc '
set -uo pipefail
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
cd "$P" || exit 1

SRC=pillow_fusion_func_v2.cpp
BAK=pillow_fusion_func_v2.cpp.bak_clip_neon

echo "== 0. 起始状态 =="
md5sum "$SRC" "$BAK"
ls -l fusion.unittest fusion.unittest.bak_before_neon 2>&1

echo "== 1. 保存当前优化版源码到 tmp =="
cp -a "$SRC" /tmp/pillow_neon_src.cpp
md5sum /tmp/pillow_neon_src.cpp

echo "== 2. 构建基线 =="
cp -a "$BAK" "$SRC"
md5sum "$SRC"
make clean > /tmp/make_clean_base.log 2>&1; echo "clean rc=$?"
make -j > /tmp/make_base.log 2>&1; echo "make rc=$?"
tail -5 /tmp/make_base.log
cp -a fusion.unittest fusion.unittest.base_rebuild && ls -l fusion.unittest.base_rebuild

echo "== 3. 恢复优化版源码并构建 =="
cp -a /tmp/pillow_neon_src.cpp "$SRC"
md5sum "$SRC"
make clean > /tmp/make_clean_neon.log 2>&1; echo "clean rc=$?"
make -j > /tmp/make_neon.log 2>&1; echo "make rc=$?"
tail -5 /tmp/make_neon.log
cp -a fusion.unittest fusion.unittest.neon_rebuild && ls -l fusion.unittest.neon_rebuild

echo "== 4. 源码已还原确认 =="
md5sum "$SRC" /tmp/pillow_neon_src.cpp
grep -c clip_u8_i32_x16 "$SRC"

echo "== 5. 基线跑一次 =="
numactl -C 3 ./fusion.unittest.base_rebuild 1 2>&1 | tail -25

echo "== 6. 优化版跑一次 =="
numactl -C 3 ./fusion.unittest.neon_rebuild 1 2>&1 | tail -25
' 2>&1 | head -140

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
