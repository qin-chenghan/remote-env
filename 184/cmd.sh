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
  # 只清理我们自己创建的宿主 /tmp 临时文件；不动容器内、不动 transfer。

  echo "== 清理前 =="
  ls -ld /tmp/184-venv-check 2>/dev/null || echo "no 184-venv-check"
  ls -l /tmp/freeze-base.txt /tmp/freeze-new.txt /tmp/184_pre_hash.txt /tmp/184_post_hash.txt 2>/dev/null || echo "no hash txt"

  echo "== 清理 =="
  rm -rf /tmp/184-venv-check
  rm -f /tmp/freeze-base.txt /tmp/freeze-new.txt /tmp/184_pre_hash.txt /tmp/184_post_hash.txt
  echo "cleaned"

  echo "== 清理后 =="
  ls -ld /tmp/184-venv-check 2>/dev/null || echo "184-venv-check gone"
  ls /tmp | grep -E "184|freeze" || echo "no leftovers"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
