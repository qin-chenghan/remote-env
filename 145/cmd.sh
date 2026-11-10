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
  # 只读：在容器内全局搜索 clamp_to_u8 / kUint8ToFloatDivisor。

  echo "== 1. 全盘搜 clamp_to_u8 =="
  docker exec fusionv1 bash -lc '
grep -rn "clamp_to_u8" /home/workspace /home/qch /opt 2>/dev/null | head -20
' 2>&1 | head -25

  echo "== 2. 搜 kUint8ToFloatDivisor =="
  docker exec fusionv1 bash -lc '
grep -rn "kUint8ToFloatDivisor" /home/workspace /home/qch /opt 2>/dev/null | head -10
' 2>&1 | head -15

  echo "== 3. workspace 结构 =="
  docker exec fusionv1 bash -lc '
ls /home/workspace/tensor 2>/dev/null
echo "-- files --"; ls /home/workspace/tensor/files 2>/dev/null | head -20
' 2>&1 | head -30

  echo "== 4. 最近修改的 cpp/h（近 7 天）=="
  docker exec fusionv1 bash -lc '
find /home/workspace /home/qch -name "*.cpp" -o -name "*.h" 2>/dev/null | xargs -r ls -lt 2>/dev/null | head -15
' 2>&1 | head -20

  echo "== 5. 任何含 uint8 转换的源文件 =="
  docker exec fusionv1 bash -lc '
grep -rln "static_cast<uint8_t>" /home/workspace /home/qch 2>/dev/null | head -10
' 2>&1 | head -15

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
