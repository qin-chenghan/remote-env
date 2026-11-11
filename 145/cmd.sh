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
  # 只读：查找 145 上是否有死存储/代码下沉的实现、trace 工具与结果文件。

  echo "== 1. 宿主机：按文件名查找 =="
  find /home/qch /home/workspace -maxdepth 5 \
    \( -iname '*dead*' -o -iname '*sink*' -o -iname '*redund*' -o -iname '*trace*' \) \
    2>/dev/null | head -30

  echo "== 2. 宿主机：按内容查找关键字 =="
  grep -rIl "DeadStore\|无效存储\|可下沉\|dead store" \
    /home/qch /home/workspace --exclude-dir=.git 2>/dev/null | head -20

  echo "== 3. 宿主机：projects 下最近修改的文件 =="
  ls -lt /home/qch/projects 2>/dev/null | head -10
  ls -lt /home/qch/projects/vllm 2>/dev/null | head -10

  echo "== 4. 容器内：关键字搜索 =="
  docker exec fusionv1 bash -lc '
grep -rIl "DeadStore\|无效存储\|可下沉" /home/qch /home/workspace --exclude-dir=.git 2>/dev/null | head -20
echo "-- projects 目录 --"
ls -lt /home/qch/projects 2>/dev/null | head -10
' 2>&1 | head -30

  echo "== 5. trace / 采样工具迹象 =="
  docker exec fusionv1 bash -lc '
command -v kperf; command -v perf; command -v valgrind; command -v qemu-aarch64
ls /opt 2>/dev/null | head -10
' 2>&1 | head -20

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
