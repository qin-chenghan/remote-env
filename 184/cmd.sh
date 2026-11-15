#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 真跑前的三项确认：11-14 单 case 变体改了什么、当前内核/页大小、profiler 落盘时机。
# 纯 CPU，不启动 vllm，不动 GPU。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TOOLKIT=/home/huawei_ts_program/litehost_perf_opt
CTR=corex5-py311
PREFIX=/opt/corex311-cpython-vllm

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  echo "== 1. 当前内核 / 页大小 / 开机时长 =="
  uname -r
  getconf PAGE_SIZE
  uptime -s 2>/dev/null || uptime
  echo "-- 最近引导 --"
  last -x reboot shutdown 2>/dev/null | head -10

  echo "== 2. profiler 落盘时机（wrapper.py 200-320） =="
  docker exec "$CTR" sed -n '190,320p' "$PREFIX/lib/python3.11/site-packages/vllm/profiler/wrapper.py" 2>&1

  echo "== 3. 当前装好的 timeline 脚本 =="
  sha256sum /home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
