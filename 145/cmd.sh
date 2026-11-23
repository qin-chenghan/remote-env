#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。定位 vllm_qemu_err.log 并提取关键内容（不整文件倾倒）。
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

  echo "== 1. 定位文件（宿主）=="
  find /home /tmp /var/tmp /var/log -maxdepth 6 -name 'vllm_qemu_err.log' 2>/dev/null | head -5

  echo "== 2. 定位文件（vllm 容器内）=="
  docker exec vllm bash -lc \
    'find /home /tmp /root -maxdepth 6 -name "vllm_qemu_err.log" 2>/dev/null | head -5' 2>&1 | head -6

  echo "== 3. 汇总每个找到的文件 =="
  for f in $(find /home /tmp /var/tmp -maxdepth 6 -name 'vllm_qemu_err.log' 2>/dev/null | head -3); do
    echo "=== $f"
    ls -lh "$f"
    wc -l "$f"
    echo '-- 前 20 行 --'
    head -20 "$f"
    echo '-- 最后 40 行 --'
    tail -40 "$f"
    echo '-- 关键行（ERROR/Traceback/qemu/fatal/signal/killed）--'
    grep -niE 'error|traceback|qemu|fatal|signal|killed|abort|SIGSEGV|SIGILL|SIGBUS' "$f" | tail -30
  done

  echo "== 4. 宿主/容器里 qemu 相关进程 =="
  ps -eo pid,etime,pcpu,args 2>/dev/null | grep -iE "qemu|vllm" | grep -v grep | cut -c1-150 | head -8
  docker exec vllm bash -lc 'ps -eo pid,etime,pcpu,args | grep -iE "qemu|vllm" | grep -v grep | cut -c1-150 | head -8' 2>&1 | head -8

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
