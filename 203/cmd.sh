#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 203 内存状况诊断：总量/可用、top 进程、容器占用、tmpfs 与 hugepage、OOM 历史。
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
  echo "== 1. 总体内存 =="
  free -h
  grep -E 'MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Writeback|SReclaimable|Shmem|HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugepagesize|AnonPages|Committed_AS|CommitLimit' /proc/meminfo

  echo "== 2. 占用最高的进程（RSS 前 25，含子进程合并前）=="
  ps -eo pid,ppid,user,rss,vsz,etime,args --sort=-rss 2>/dev/null | head -26

  echo "== 3. 按进程名合并 RSS（前 15）=="
  ps -eo rss,comm --no-headers 2>/dev/null | awk '{a[$2]+=$1} END{for(k in a) printf "%10.1f MB  %s\n", a[k]/1024, k}' | sort -rn | head -15

  echo "== 4. 容器内存占用 =="
  docker ps --format '{{.ID}}  {{.Names}}  {{.Status}}' 2>&1 | head -15
  timeout 90 docker stats --no-stream --format '{{.Name}}  mem={{.MemUsage}}  pids={{.PIDs}}' 2>&1 | head -15

  echo "== 5. tmpfs / shm（内存记账）=="
  df -h /dev/shm /tmp /run 2>&1 | head -6
  du -sh /dev/shm 2>/dev/null | head -3
  du -sh /dev/shm/* 2>/dev/null | sort -rh | head -10

  echo "== 6. hugepage =="
  cat /proc/sys/vm/nr_hugepages 2>/dev/null
  grep -i huge /proc/meminfo

  echo "== 7. overcommit =="
  cat /proc/sys/vm/overcommit_memory /proc/sys/vm/overcommit_ratio 2>/dev/null
  cat /proc/sys/vm/swappiness 2>/dev/null

  echo "== 8. OOM / 内存告警历史（近 20 条）=="
  (dmesg -T 2>/dev/null || dmesg 2>/dev/null) | grep -iE 'out of memory|oom-kill|oom_reaper|killed process|memory cgroup' | tail -20 || echo "无 OOM 记录或无 dmesg 权限"
  echo "--- 本次启动以来 OOM 计数 ---"
  grep -c . /dev/null 2>/dev/null; journalctl -k --since "-24h" 2>/dev/null | grep -icE 'out of memory|oom-kill|killed process' || echo "journal 不可读"

  echo "== 9. 谁在申请/持有大块内存（活跃 vllm 进程）=="
  ps -eo pid,rss,etime,args 2>/dev/null | grep -E 'vllm|bench_driver|ixsys|python' | grep -v grep | head -10
  docker exec corex5-py311 bash -c 'ps -eo pid,rss,etime,args | grep -E "vllm|bench_driver" | grep -v grep | head -10' 2>&1

  echo "== 10. 磁盘（与内存无关，顺带）=="
  df -h / /home | tail -2

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
