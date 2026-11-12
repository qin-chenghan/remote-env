#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 203 第二轮：宿主内存充足，查显存、容器 cgroup OOM 计数、近期 run 日志里的内存报错。
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
  echo "== 1. 显存现状 =="
  timeout 30 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | head -30
  echo "--- 显存总览 ---"
  timeout 30 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'MiB /' | head -10

  echo "== 2. 容器 cgroup 内存与 OOM 计数 =="
  for c in $(docker ps -q 2>/dev/null); do
    full=$(docker inspect -f '{{.Id}}' "$c" 2>/dev/null)
    name=$(docker inspect -f '{{.Name}}' "$c" 2>/dev/null)
    d=/sys/fs/cgroup/docker/$full
    [ -d "$d" ] || d=$(ls -d /sys/fs/cgroup/docker/${full:0:12}* 2>/dev/null | head -1)
    echo "---- $name ($d)"
    [ -d "$d" ] && {
      printf 'memory.max=%s  current=%s\n' "$(cat "$d/memory.max" 2>/dev/null)" "$(cat "$d/memory.current" 2>/dev/null)"
      echo -n "memory.events: "; tr '\n' ' ' < "$d/memory.events" 2>/dev/null; echo
      echo -n "memory.swap.max: "; cat "$d/memory.swap.max" 2>/dev/null; echo
    } || echo "cgroup dir not found"
  done

  echo "== 3. 内核侧 iluvatar / 内存报错 =="
  dmesg -T 2>/dev/null | grep -iE 'iluvatar|corex|oom|out of memory|alloc.*fail' | tail -25 || echo "dmesg 不可读"

  echo "== 4. 最近一次 run 的日志里找内存类报错 =="
  R=$(ls -dt /home/qch/scripts/litehost_perf/vllmBench/*/ 2>/dev/null | head -3)
  echo "$R"
  for d in $R; do
    echo "---- $d"
    ls -l "$d" 2>/dev/null | head -5
    grep -iE 'out of memory|OutOfMemory|OOM|CUDA error|allocation failed|insufficient memory|memory pool' "$d/logs/server.log" 2>/dev/null | tail -5
    tail -3 "$d/logs/server.log" 2>/dev/null
  done

  echo "== 5. 近期失败/异常痕迹 =="
  find /home -maxdepth 5 -name 'server.log' -newermt '-3 days' 2>/dev/null | head -10 | while read -r f; do
    n=$(grep -icE 'out of memory|oom|allocation failed' "$f" 2>/dev/null)
    echo "$n  $f"
  done

  echo "== 6. 磁盘与日志占用（'/' 只剩几百兆，可能与报错混淆）=="
  df -h / | tail -1
  du -sh /var/log /var/cache/dnf 2>/dev/null | head -4
  ls -lt /var/log 2>/dev/null | head -6

  echo "== 7. 当前是否有 GPU 进程 =="
  timeout 30 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -iE 'process|python|vllm' | head -10 || echo "无进程列表输出"
  ps -eo pid,rss,etime,args 2>/dev/null | grep -E 'vllm|bench_driver|light_host' | grep -v grep | head -5 || echo "无 vllm 进程"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
