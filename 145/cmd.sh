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
  # 只读：确认工作区当前状态、备份文件、构建方式，为"基线 vs 优化"对比做准备。

  echo "== 1. 定位工作区 =="
  docker exec fusionv1 bash -lc '
    find /home/workspace -maxdepth 5 -type f -name "pillow_fusion_func_v2.cpp" 2>/dev/null | head -5
    find /home/workspace -maxdepth 5 -type f -name "*.bak*" -o -maxdepth 5 -type f -name "fusion.unittest*" 2>/dev/null | head -10
  ' 2>&1 | head -20

  echo "== 2. 目标目录清单 =="
  docker exec fusionv1 bash -lc '
    W=$(dirname "$(find /home/workspace -maxdepth 5 -type f -name "pillow_fusion_func_v2.cpp" 2>/dev/null | head -1)")
    echo "W=$W"
    [ -d "$W" ] && ls -la "$W" | head -40
  ' 2>&1 | head -50

  echo "== 3. 当前源码是否已含 NEON 优化 =="
  docker exec fusionv1 bash -lc '
    W=$(dirname "$(find /home/workspace -maxdepth 5 -type f -name "pillow_fusion_func_v2.cpp" 2>/dev/null | head -1)")
    F=$W/pillow_fusion_func_v2.cpp
    echo "hit clip_u8_i32_x16: $(grep -c clip_u8_i32_x16 "$F" 2>/dev/null)"
    echo "hit clip_norm_x16:    $(grep -c clip_norm_x16 "$F" 2>/dev/null)"
    echo "hit vqmovun_s32:      $(grep -c vqmovun_s32 "$F" 2>/dev/null)"
    wc -l "$F"
    ls -l "$W"/*.bak* 2>/dev/null | head -5
  ' 2>&1 | head -20

  echo "== 4. 备份源码与当前源码的差异规模 =="
  docker exec fusionv1 bash -lc '
    W=$(dirname "$(find /home/workspace -maxdepth 5 -type f -name "pillow_fusion_func_v2.cpp" 2>/dev/null | head -1)")
    B=$W/pillow_fusion_func_v2.cpp.bak_clip_neon
    if [ -f "$B" ]; then
      diff -u "$B" "$W/pillow_fusion_func_v2.cpp" | head -80
      echo "--- diff 行数 ---"
      diff "$B" "$W/pillow_fusion_func_v2.cpp" | wc -l
    else
      echo "no backup $B"
    fi
  ' 2>&1 | head -100

  echo "== 5. Makefile =="
  docker exec fusionv1 bash -lc '
    W=$(dirname "$(find /home/workspace -maxdepth 5 -type f -name "pillow_fusion_func_v2.cpp" 2>/dev/null | head -1)")
    cat "$W/Makefile" 2>&1 | head -60
  ' 2>&1 | head -70

  echo "== 6. 测试程序用法 =="
  docker exec fusionv1 bash -lc '
    W=$(dirname "$(find /home/workspace -maxdepth 5 -type f -name "pillow_fusion_func_v2.cpp" 2>/dev/null | head -1)")
    ls -l "$W/fusion.unittest"* 2>/dev/null
    grep -rn "argv\|argc\|usage\|Usage\|step" "$W" --include="*.cpp" --include="*.h" 2>/dev/null | head -20
  ' 2>&1 | head -30

  echo "== 7. benchmark 文档 =="
  docker exec fusionv1 bash -lc '
    W=$(dirname "$(find /home/workspace -maxdepth 5 -type f -name "pillow_fusion_func_v2.cpp" 2>/dev/null | head -1)")
    ls "$W"/*.md 2>/dev/null
    for f in "$W/benchmark.md" "$W"/*benchmark*.md; do
      [ -f "$f" ] && { echo "--- $f ---"; head -80 "$f"; }
    done
  ' 2>&1 | head -100

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
