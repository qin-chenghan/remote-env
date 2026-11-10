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
  # 只读：确认宿主机 python 是否有 numpy/PIL，容器 yum 能否提供这两个包。

  echo "== 1. 宿主机 python =="
  for p in /usr/bin/python3 /usr/local/bin/python3; do
    [ -x "$p" ] || continue
    echo "-- $p --"
    "$p" -V 2>&1
    "$p" -c "import numpy,PIL;print('numpy',numpy.__version__,'PIL',PIL.__version__)" 2>&1 | tail -1
  done
  rpm -qa 2>/dev/null | grep -iE '^python3-(numpy|pillow)' | head -5

  echo "== 2. 容器内已装包 =="
  docker exec fusionv1 bash -lc '
rpm -qa 2>/dev/null | grep -iE "numpy|pillow|scipy" | head -5
echo "-- yum 仓库 --"
ls /etc/yum.repos.d/ 2>/dev/null | head -5
' 2>&1 | head -12

  echo "== 3. yum 是否能提供（仅查询）=="
  docker exec fusionv1 bash -lc '
timeout 90 yum list available python3-numpy python3-pillow 2>&1 | tail -12
' 2>&1 | head -20

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
