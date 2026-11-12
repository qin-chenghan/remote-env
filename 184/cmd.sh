#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 正确校验保全（相对路径 hash 对比），并删除仓库里的数据副本（不该上库）。
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
  RUN=/home/s00806700/litehost_perf_opt/vllmBench/litehost_gap_20261112_145924
  TAR=$(ls -t /home/qch/backup/litehost_gap_20261112_145924-*.tar.gz 2>/dev/null | head -1)
  EX="$DIR/export/litehost_gap_20261112_145924_full"

  echo "== 1. 三份副本状态 =="
  [ -d "$RUN" ] && echo "原始目录: OK  $(du -sh "$RUN" | cut -f1)" || echo "原始目录: MISSING"
  [ -f "$TAR" ] && echo "tar 备份: OK  $(du -h "$TAR" | cut -f1)  $TAR" || echo "tar 备份: MISSING"
  [ -d "$EX" ] && echo "仓库副本: 存在 $(du -sh "$EX" | cut -f1)" || echo "仓库副本: 不存在"

  echo "== 2. 用相对路径 hash 校验 =="
  man() { ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) | sort; }
  man "$RUN" > /tmp/a.txt
  if [ -d "$EX" ]; then
    man "$EX" > /tmp/b.txt
    if cmp -s /tmp/a.txt /tmp/b.txt; then
      echo "VERIFIED: 原始目录与仓库副本 $(wc -l < /tmp/a.txt) 个文件 hash 完全一致"
    else
      echo "MISMATCH:"; diff /tmp/a.txt /tmp/b.txt | head -10
    fi
  fi
  echo "原始目录文件数: $(wc -l < /tmp/a.txt)"

  echo "== 3. 校验 tar 可解且文件数一致 =="
  if [ -f "$TAR" ]; then
    echo "tar 内条目数: $(tar -tzf "$TAR" | wc -l)"
    tar -tzf "$TAR" > /tmp/t.txt 2>&1 && echo "tar 完整性: OK"
  fi

  echo "== 4. 删除仓库里的数据副本（不该上库）=="
  if [ -d "$DIR/export" ]; then
    echo "将删除: $DIR/export"
    ls -la "$DIR/export" | head
    if [ -d "$RUN" ] && [ -f "$TAR" ]; then
      rm -rf "$DIR/export"
      echo "已删除（原始目录与 tar 备份均存在）"
    else
      echo "保留：原始目录或 tar 备份缺失，先不删"
    fi
  else
    echo "仓库内无 export 目录"
  fi

  echo "== 5. 确认未上库 =="
  git -C "$DIR/.." ls-files 184/export | head
  git -C "$DIR/.." status --short | head

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
