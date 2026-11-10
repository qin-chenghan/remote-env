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
  echo "== 1. 宿主机 /home/qch/projects =="
  ls -la /home/qch/projects 2>&1 | head -20
  git -C /home/qch/projects rev-parse --abbrev-ref HEAD 2>&1
  find /home/qch/projects -maxdepth 3 -name 'lib_preprocess.cpp' 2>/dev/null | head -5
  find /home/qch/projects -maxdepth 3 -type d -name workplace 2>/dev/null | head -5

  echo "== 2. 容器内 /home/qch/projects =="
  docker exec fusionv1 bash -lc '
ls -la /home/qch/projects 2>&1 | head -20
echo "-- 找 lib_preprocess.cpp --"
find /home/qch /home/workspace -maxdepth 6 -name "lib_preprocess.cpp" 2>/dev/null | head -5
echo "-- 找 workplace 目录 --"
find /home/qch /home/workspace -maxdepth 6 -type d -name "workplace" 2>/dev/null | head -5
' 2>&1 | head -35

  echo "== 3. 容器内其它 python 环境 =="
  docker exec fusionv1 bash -lc '
ls -d /opt/* 2>/dev/null | head -10
for p in /usr/bin/python3 /usr/local/bin/python3 /opt/*/bin/python3; do
  [ -x "$p" ] || continue
  echo "-- $p --"
  "$p" -V 2>&1
  "$p" -c "import numpy,PIL;print(\"numpy\",numpy.__version__,\"PIL\",PIL.__version__)" 2>&1 | tail -1
done
command -v pip3 || echo NO_PIP3
command -v yum || command -v dnf || echo NO_PKG_MGR
' 2>&1 | head -30

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
