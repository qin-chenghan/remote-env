#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。检查 /home/l00946765 —— 找 kperf 模块/插桩来源与相关脚本。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

U=/home/l00946765

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 目录概览 =="
  ls -ld "$U" 2>&1; du -sh "$U" 2>/dev/null
  ls -lat "$U" 2>&1 | head -20

  echo "== 2. 两层目录树 =="
  find "$U" -maxdepth 2 -type d 2>/dev/null | head -25

  echo "== 3. 找 kperf 相关文件 =="
  find "$U" -maxdepth 5 \( -iname "*kperf*" -o -iname "*kperf*" \) 2>/dev/null | head -15
  grep -rIl "kperf_start_type" "$U" 2>/dev/null | head -10

  echo "== 4. 找 python 环境与 wheel =="
  find "$U" -maxdepth 4 -name "pyvenv.cfg" 2>/dev/null | head -6
  find "$U" -maxdepth 4 \( -name "*.whl" -o -name "*.tar.gz" -o -name "*.zip" \) 2>/dev/null | head -12
  find "$U" -maxdepth 5 -path "*site-packages/kperf*" 2>/dev/null | head -6

  echo "== 5. 找脚本与 dockerfile =="
  find "$U" -maxdepth 4 \( -name "*.sh" -o -name "Dockerfile*" -o -name "*.py" \) 2>/dev/null | head -20

  echo "== 6. 最近改动 =="
  find "$U" -maxdepth 4 -type f -mtime -10 2>/dev/null | head -15

  echo "== 7. 与该 run 相关的线索（zzy_dryrun 等）=="
  ls -lat /tmp/zzy_dryrun_* 2>/dev/null | head -6
  grep -l "kperf" /tmp/zzy_dryrun_*.log 2>/dev/null | head -3

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
