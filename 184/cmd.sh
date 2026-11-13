#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 184 101902 run 失败根因：第 8 个 case 正式请求未完成，取 bench 全日志、server 时段日志、dmesg。
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
  C=corex5-py311
  P=/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261113_101902
  dex() { timeout 150 docker exec "$C" bash -c "$1"; }

  echo "== 1. 本次 run 的配置（确认 case 矩阵）=="
  dex "cat $P/config.txt"

  echo "== 2. 失败 case 的 bench 日志全文（前 70 行）=="
  dex "head -n 70 $P/logs/bench_bs8_in2048_out1024.log"

  echo "== 3. 上一个 case（2048/128）的日志尾部，看是否有前兆 =="
  dex "tail -n 25 $P/logs/bench_bs8_in2048_out128.log"

  echo "== 4. 失败 case 的 case.json =="
  dex "cat $P/litehost/bs8_in2048_out1024/case.json 2>&1 | head -c 800; echo"

  echo "== 5. server.log 11:25-11:35 时段的告警与错误（去掉 ASGI 关闭时的噪声）=="
  dex "grep -nE 'WARNING|ERROR|CRITICAL|Exception|Traceback' $P/logs/server.log | grep -vE 'Exception in ASGI application|Traceback \(most recent' | tail -60"

  echo "== 6. server.log 里 11:28-11:35 的原始行（定位事发时刻）=="
  dex "awk '/11:28|11:29|11:3[0-5]/' $P/logs/server.log | grep -vE 'MALLOC|^$' | tail -80"

  echo "== 7. 引擎侧是否有 abort/OOM/超时记录 =="
  dex "grep -nE 'abort|Abort|out of memory|OOM|CUDA error|iluvatar|timeout|Timeout|stuck|deadlock' $P/logs/server.log | tail -30"

  echo "== 8. 采集侧窗口文件（失败 case 是否有 window）=="
  dex "cat $P/litehost/bs8_in2048_out1024/window.json 2>&1 | head -c 400; echo"
  dex "ls -l $P/litehost/bs8_in2048_out1024/ $P/litehost/bs8_in2048_out128/"

  echo "== 9. summary.csv 内容 =="
  dex "cat $P/summary.csv"

  echo "== 10. 宿主 dmesg 同时段 GPU/驱动异常 =="
  dmesg -T 2>/dev/null | grep -iE 'iluvatar|corex|xid|reset|hang|timeout|oom' | tail -20 || echo "dmesg 无相关记录"
  ls -l /var/log/pcp >/dev/null 2>&1 || true

  echo "== 11. 当前 GPU 与进程状态 =="
  /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'MiB /' | head -6
  docker exec $C bash -c 'ps -eo pid,etime,args | grep -E "vllm|bench_driver" | grep -v grep | head -5' 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
