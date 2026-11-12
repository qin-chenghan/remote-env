#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 检查 /usr/local/corex-5.0.0/vllmBench/litehost_gap_20261112_150257 是什么、内容是否完整。
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
  P=/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261112_150257

  echo "== 1. 路径本身 =="
  ls -ld "$P"
  readlink -f "$P"
  [ -L "$P" ] && echo "是符号链接 -> $(readlink "$P")"
  du -sh "$P" 2>/dev/null
  echo "顶层内容:"
  ls -la "$P"

  echo "== 2. 文件清单（相对路径 + 大小 + 时间）=="
  ( cd "$P" 2>/dev/null && find . -type f -printf '%10s  %TY-%Tm-%Td %TH:%TM  %p\n' | sort -k4 ) | head -60
  echo "文件数: $(find "$P" -type f 2>/dev/null | wc -l)"

  echo "== 3. 关键文件内容 =="
  for f in config.txt summary.csv meta.json; do
    if [ -f "$P/$f" ]; then echo "--- $f ---"; head -40 "$P/$f"; fi
  done
  echo "--- host_summary 目录 ---"
  ls -la "$P/host_summary" 2>/dev/null
  for f in "$P"/host_summary/*; do
    [ -f "$f" ] && { echo "--- $f ---"; head -25 "$f"; }
  done

  echo "== 4. 和已保全的那次（145924）对比 =="
  R=/home/s00806700/litehost_perf_opt/vllmBench/litehost_gap_20261112_145924
  if [ -d "$R" ]; then
    echo "145924 文件数: $(find "$R" -type f | wc -l)   $(du -sh "$R" | cut -f1)"
    echo "150257 文件数: $(find "$P" -type f 2>/dev/null | wc -l)   $(du -sh "$P" 2>/dev/null | cut -f1)"
    echo "-- 两边顶层目录 --"
    diff <(cd "$R" && find . -maxdepth 2 | sort) <(cd "$P" && find . -maxdepth 2 | sort) | head -40
  else
    echo "145924 原目录不存在"
  fi

  echo "== 5. 归属与时间 =="
  stat -c '%U:%G  %y  %n' "$P" 2>/dev/null
  stat -c '%U:%G  %y  %n' "$(dirname "$P")" 2>/dev/null

  echo "== 6. 清理仓库里的第三方数据副本（不该上库）=="
  EX="$DIR/export/litehost_gap_20261112_145924_full"
  TAR=$(ls -t /home/qch/backup/litehost_gap_20261112_145924-*.tar.gz 2>/dev/null | head -1)
  if [ -d "$DIR/export" ]; then
    if [ -d "$R" ] && [ -f "$TAR" ]; then
      rm -rf "$DIR/export"; echo "已删除 $DIR/export（原始目录+tar 均在）"
    else
      echo "保留 $DIR/export：原始目录或 tar 缺失"
    fi
  else
    echo "仓库内无 export 目录"
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
