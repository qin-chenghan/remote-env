#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 150257 目录在 host 上不存在，去容器内定位并检查。
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
  PB=/usr/local/corex-5.0.0/vllmBench

  echo "== 1. host 上到底有没有 =="
  ls -ld /usr/local/corex-5.0.0 2>&1
  ls -ld "$PB" 2>&1
  ls -ld "$P" 2>&1

  echo "== 2. 所有容器（含已停止）=="
  docker ps -a --format '{{.ID}}  {{.Names}}  {{.Image}}  {{.Status}}'

  echo "== 3. 在运行中的容器里找这个目录 =="
  FOUND=""
  for c in $(docker ps -q); do
    n=$(docker inspect -f '{{.Name}}' "$c" 2>/dev/null)
    if docker exec "$c" bash -c "test -d '$P'" 2>/dev/null; then
      echo "命中: $n ($c)"
      FOUND="$c"
    else
      echo "未命中: $n ; vllmBench 目录:"
      docker exec "$c" bash -c "ls -ld '$PB'/* 2>&1 | tail -8" 2>&1
    fi
  done

  echo "== 4. 命中容器的详细内容 =="
  if [ -n "$FOUND" ]; then
    docker inspect -f '{{.Name}} {{.Id}} img={{.Config.Image}}' "$FOUND"
    echo "-- mounts --"
    docker inspect -f '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' "$FOUND"
    echo "-- 顶层 --"
    docker exec "$FOUND" ls -la "$P"
    echo "-- 文件清单 --"
    docker exec "$FOUND" bash -c "cd '$P' && find . -type f -printf '%10s  %TY-%Tm-%Td %TH:%TM  %p\n' | sort -k4 | head -60"
    echo "文件数: $(docker exec "$FOUND" bash -c "find '$P' -type f | wc -l")"
    echo "大小:   $(docker exec "$FOUND" du -sh "$P" | cut -f1)"
    echo "-- config.txt --"
    docker exec "$FOUND" bash -c "head -40 '$P/config.txt' 2>&1"
    echo "-- summary.csv --"
    docker exec "$FOUND" bash -c "head -20 '$P/summary.csv' 2>&1"
    echo "-- host_summary/report.txt --"
    docker exec "$FOUND" bash -c "head -40 '$P/host_summary/report.txt' 2>&1"
    echo "-- host_summary/four_rank_totals.csv --"
    docker exec "$FOUND" bash -c "head -10 '$P/host_summary/four_rank_totals.csv' 2>&1"
  else
    echo "所有运行中容器都没有 $P"
    echo "== 4b. 全盘按名字搜（容器内）=="
    for c in $(docker ps -q); do
      n=$(docker inspect -f '{{.Name}}' "$c" 2>/dev/null)
      echo "--- $n ---"
      docker exec "$c" bash -c "find / -maxdepth 6 -name 'litehost_gap_20261112_15*' -print 2>/dev/null | head -10"
    done
  fi

  echo "== 5. host 上按名字搜（含 overlay 挂载点之外）=="
  find /home /usr/local /data /opt -maxdepth 6 -name 'litehost_gap_20261112_15*' -print 2>/dev/null | head -20

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
