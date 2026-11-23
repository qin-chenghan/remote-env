#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
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
  # 关闭多流：rmmod + insmod itr_multi_compute_engine=0（203 的模块在 updates/ 下）。

  K=$(uname -r)
  MOD="/lib/modules/$K/updates/iluvatar.ko"

  echo "== 0. 现状（确认没人用）=="
  lsmod | grep iluvatar || echo "模块未加载"
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null || echo "无参数文件"
  ls -l "$MOD" 2>&1
  modinfo -p "$MOD" 2>&1 | grep -i multi || echo "modinfo 无 multi 参数"
  echo "-- GPU 进程 --"
  timeout 20 /usr/local/corex/bin/ixsmi 2>&1 | sed -n '/Processes/,$p' | head -10
  echo "-- 谁打开着设备 --"
  fuser -vm /dev/iluvatar* 2>&1 | head -10 || echo "无进程占用"
  echo "-- 相关进程 --"
  pgrep -af 'vllm.entrypoints|bench_driver|api_server' 2>/dev/null | head -5 || echo "无 vllm/bench 进程"

  echo "== 1. 卸载模块 =="
  rmmod iluvatar 2>&1
  echo "rmmod rc=$?"
  lsmod | grep iluvatar || echo "已卸载"
  ls /dev/iluvatar* 2>&1 | head -3

  echo "== 2. 以 multi_engine=0 重新加载 =="
  insmod "$MOD" itr_multi_compute_engine=0 2>&1
  echo "insmod rc=$?"

  echo "== 3. 验证 =="
  lsmod | grep iluvatar
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>&1
  dmesg 2>/dev/null | grep 'is okay' | tail -8
  ls -l /dev/iluvatar* 2>&1 | head -5
  timeout 20 /usr/local/corex/bin/ixsmi --query-gpu=index,memory.used --format=csv,noheader 2>&1 | head -8

  echo "== 4. 容器内是否仍可用 =="
  docker ps --filter name=corex5-py311 --format '{{.Names}}\t{{.Status}}' 2>&1
  docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 \
    /opt/corex311/bin/python -c 'import torch;print("devices",torch.cuda.device_count())' 2>&1 | tail -3

  echo "== 5. 收尾 =="
  df -h /home | tail -1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
