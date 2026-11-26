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
  echo "### 本轮只读：只列目录、读 summary.csv / report.txt / config.txt，"
  echo "###           不启动服务、不写、不删。"
  set +x

  # ---- 命令开始 ----
  echo
  echo "== 0. 空间与顶层目录 =="
  df -h /home | tail -1
  ls -lt /home/qch 2>/dev/null | head -30

  echo
  echo "== 1. 定位 e2e-analysis-base1 相关路径 =="
  find /home/qch -maxdepth 6 \( -iname '*e2e*' -o -iname '*base1*' \) \
      -not -path '*/docker/*' -not -path '*/.git/*' 2>/dev/null | head -80

  echo
  echo "== 2. 今天新产生的 summary.csv / report.txt / config.txt =="
  echo "-- summary.csv --"
  find /home/qch -maxdepth 8 -name 'summary.csv' -newermt '2026-11-26 00:00' 2>/dev/null | head -40
  echo "-- report*.txt --"
  find /home/qch -maxdepth 8 -name 'report*.txt' -newermt '2026-11-26 00:00' 2>/dev/null | head -40
  echo "-- config.txt --"
  find /home/qch -maxdepth 8 -name 'config.txt' -newermt '2026-11-26 00:00' 2>/dev/null | head -40

  echo
  echo "== 3. 内容：summary.csv（benchmark 指标） =="
  while IFS= read -r -d '' f; do
      echo
      echo "---- $f ----"
      cat "$f"
  done < <(find /home/qch -maxdepth 8 -name 'summary.csv' -newermt '2026-11-26 00:00' -print0 2>/dev/null | head -z -n 40)

  echo
  echo "== 4. 内容：report*.txt（TSHG） =="
  while IFS= read -r -d '' f; do
      echo
      echo "---- $f ----"
      cat "$f"
  done < <(find /home/qch -maxdepth 8 -name 'report*.txt' -newermt '2026-11-26 00:00' -print0 2>/dev/null | head -z -n 40)

  echo
  echo "== 5. 内容：config.txt（运行配置） =="
  while IFS= read -r -d '' f; do
      echo
      echo "---- $f ----"
      cat "$f"
  done < <(find /home/qch -maxdepth 8 -name 'config.txt' -newermt '2026-11-26 00:00' -print0 2>/dev/null | head -z -n 40)

  echo
  echo "== 6. 运行脚本（若在 /home/qch 下且是文本） =="
  for f in $(find /home/qch -maxdepth 4 -type f \( -name '*e2e*' -o -name '*base1*' \) \
                 -size -200k 2>/dev/null | head -6); do
      echo
      echo "---- $f ----"
      head -100 "$f" 2>/dev/null
  done

  echo
  echo "== 7. 结果目录树（最多两层） =="
  for d in $(find /home/qch -maxdepth 4 -type d \( -iname '*e2e*' -o -iname '*base1*' \) \
                 -not -path '*/.git/*' 2>/dev/null | head -10); do
      echo "-- $d --"
      ls -l "$d" 2>/dev/null | head -30
      find "$d" -maxdepth 2 -type f \( -name '*.csv' -o -name '*.txt' -o -name '*.json' \) 2>/dev/null | head -40
  done
  # ---- 命令结束 ----

} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
