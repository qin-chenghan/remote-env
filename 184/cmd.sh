#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：快速确认 184 是否空闲，准备重采 4k。
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
  echo "== kernel =="
  uname -r; getconf PAGE_SIZE
  uptime

  echo "== who =="
  who 2>&1 | head -8

  echo "== vllm / bench processes =="
  ps -eo pid,user,etime,args 2>/dev/null | grep -E 'vllm.entrypoints|bench_driver|lhctl|vllmBench|timeline_opt' | grep -v grep | cut -c1-180 | head -10
  echo "(空=没有)"

  echo "== gpu processes (ixsmi full) =="
  ixsmi 2>&1 | tail -25

  echo "== containers =="
  docker ps --format '{{.Names}}\t{{.Status}}' 2>&1 | head -8

  echo "== port 8000 =="
  ss -lntp 2>/dev/null | grep ':8000' || echo "  8000 未占用"

  echo "== cpu top =="
  ps -eo pcpu,pmem,user,args --sort=-pcpu 2>/dev/null | head -6 | cut -c1-160

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
