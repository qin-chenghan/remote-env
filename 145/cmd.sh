#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。确认容器重启时间、server.log 头部根因、是否 OOM、harness 进程是否还在。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
RUN=/home/huawei_ts_program/litehost_perf_opt/vllmBench/litehost_gap_20261120_095754

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 容器时间线 =="
  docker inspect "$C" --format 'created={{.Created}} startedAt={{.State.StartedAt}} finished={{.State.FinishedAt}} restarts={{.RestartCount}} status={{.State.Status}}'
  docker inspect "$C" --format 'env LD_LIBRARY_PATH = {{range .Config.Env}}{{println .}}{{end}}' | grep -i ld_library || true
  stat -c '%n  mtime=%y' "$RUN" "$RUN/logs/server.log" 2>/dev/null

  echo "== 2. server.log 头部（真正的第一个错误）=="
  docker exec "$C" bash -lc "head -60 $RUN/logs/server.log" 2>&1 | grep -vE "^\s*$" | head -40

  echo "== 3. preflight.log =="
  docker exec "$C" bash -lc "cat $RUN/logs/preflight.log" 2>&1 | head -10

  echo "== 4. harness 进程是否还活着 =="
  docker exec "$C" bash -lc \
    'ps -eo pid,ppid,etime,stat,args | grep -E "vllmBench|litehost_gap|procutil|bench_driver" | grep -v grep | cut -c1-140' 2>&1 | head -8
  echo "-- 容器内 bash 进程 --"
  docker exec "$C" bash -lc 'ps -eo pid,ppid,etime,stat,args | grep -E "bash -lc" | grep -v grep | head -5 | cut -c1-140' 2>&1

  echo "== 5. OOM / 内核日志 =="
  dmesg 2>/dev/null | tail -20 | grep -iE "oom|killed process|vllm" | tail -6 || echo "无 OOM 记录"
  free -g | sed -n 1,2p

  echo "== 6. 容器内 /home 是不是镜像副本 =="
  docker exec "$C" bash -lc 'findmnt -T /home 2>/dev/null | tail -2; ls -ld /home/huawei_ts_program /home/model 2>/dev/null' 2>&1 | head -6

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
