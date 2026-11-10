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
  echo "== 1. 宿主机仓库内容（两层）=="
  find /home/qch/projects/vllm -maxdepth 2 -type d 2>/dev/null | head -20
  echo "-- workplace --"
  ls -la /home/qch/projects/vllm/workplace 2>&1 | head -15
  echo "-- edition1 --"
  ls -la /home/qch/projects/vllm/workplace/edition1 2>&1 | head -10
  echo "-- 文件计数 --"
  find /home/qch/projects/vllm -type f 2>/dev/null | wc -l

  echo "== 2. 容器内仓库内容 =="
  docker exec fusionv1 bash -lc '
find /home/qch/projects/vllm -maxdepth 2 2>/dev/null | head -20
echo "-- 文件计数 --"
find /home/qch/projects/vllm -type f 2>/dev/null | wc -l
echo "-- 关键文件 --"
ls -l /home/qch/projects/vllm/workplace/lib_preprocess.cpp 2>&1
' 2>&1 | head -30

  echo "== 3. 挂载关系 =="
  docker inspect fusionv1 --format '{{range .HostConfig.Binds}}{{.}}{{"\n"}}{{end}}' 2>&1 | head -10
  docker exec fusionv1 bash -lc 'stat -c "%d %i %n" /home/qch 2>/dev/null; ls -di /home/qch' 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
