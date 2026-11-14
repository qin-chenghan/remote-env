#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 确认 4k3(15:51-15:56) 与 64k3(16:01-16:06) 之间是否发生过重启 —— 只有重启过，
# 两次才是不同页大小的内核。纯 CPU,不启动 vllm,不动 GPU。
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
  echo "== 1. 当前引导 =="
  date '+local now: %Y-%m-%d %H:%M:%S %Z'
  uptime -s
  uptime -p
  uname -a
  getconf PAGE_SIZE
  cat /proc/cmdline

  echo "== 2. 重启记录(wtmp,跨引导) =="
  last -x reboot shutdown 2>/dev/null | head -20

  echo "== 3. 引导列表 =="
  journalctl --list-boots --no-pager 2>/dev/null | tail -10

  echo "== 4. 每次引导的内核版本 =="
  for b in 0 -1 -2 -3 -4; do
    echo "---- boot $b"
    journalctl -b "$b" -k --no-pager -o cat 2>/dev/null | grep -m1 -i 'Linux version'
    journalctl -b "$b" --no-pager 2>/dev/null | sed -n '1p' | cut -c1-80
  done

  echo "== 5. 引导项 =="
  (grubby --default-kernel 2>/dev/null || grub2-editenv list 2>/dev/null || cat /boot/grub2/grubenv 2>/dev/null) | head -5
  ls -l --time-style=long-iso /boot/vmlinuz* 2>/dev/null | head -10
  ls -l --time-style=long-iso /boot/*64k* /boot/*4k* 2>/dev/null | head -10

  echo "== 6. 两次采集的目录时间 =="
  for d in /home/qch/scripts/timeline/4k3 /home/qch/scripts/timeline/64k3; do
    stat -c '%n  mtime=%y' "$d" "$d/run_env.txt" "$d/logs/server.log" 2>/dev/null
    grep -m2 -E 'Starting vLLM|Shutting down|Application shutdown complete' "$d/logs/server.log" 2>/dev/null
    head -2 "$d/logs/server.log" 2>/dev/null | cut -c1-110
    tail -1 "$d/logs/server.log" 2>/dev/null | cut -c1-110
  done

  echo "== 7. 是否有切内核的脚本 =="
  ls -l --time-style=long-iso /home/qch/scripts/ 2>/dev/null | head -20
  grep -rlniE 'page_size|64k|64K|grubby|grub2-editenv' /home/qch/scripts/ 2>/dev/null | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
