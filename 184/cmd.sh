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
  # 重启后 ixsmi 无法与 iluvatar 驱动通信：只读诊断，不加载/不重装。

  echo "== 1. 主机与内核 =="
  uname -a
  uptime
  echo "-- 最近重启 --"
  last reboot 2>/dev/null | head -5

  echo "== 2. 模块状态 =="
  lsmod 2>/dev/null | grep -i iluvatar || echo "iluvatar NOT loaded"
  echo "-- modinfo --"
  modinfo iluvatar 2>&1 | grep -E "filename|version|vermagic|license" | head -10

  echo "== 3. 设备节点 =="
  ls -l /dev/iluvatar* 2>&1 | head -12

  echo "== 4. dmesg 驱动相关 =="
  dmesg 2>/dev/null | grep -iE "iluvatar|corex|version magic|module verification" | tail -50

  echo "== 5. 模块文件与内核匹配 =="
  echo "-- 当前内核 --"; uname -r
  echo "-- 模块路径 --"; ls -l "/lib/modules/$(uname -r)/kernel/drivers/misc/iluvatar.ko" 2>&1
  echo "-- 已有内核目录 --"; ls /lib/modules 2>/dev/null

  echo "== 6. modprobe.d / 自动加载配置 =="
  grep -rin iluvatar /etc/modprobe.d/ /etc/modules-load.d/ 2>/dev/null | head -10 || echo "无配置"
  ls /etc/modprobe.d/ 2>/dev/null | head -10

  echo "== 7. 驱动参数（若已加载）=="
  for f in /sys/module/iluvatar/parameters/*; do
    [ -f "$f" ] && echo "$(basename "$f") = $(cat "$f" 2>/dev/null)"
  done 2>/dev/null || true

  echo "== 8. 容器状态 =="
  docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | head -15

  echo "== 9. 容器内视角 =="
  docker exec corex5-py311 sh -c "
echo '-- /dev/iluvatar* --'; ls -l /dev/iluvatar* 2>&1 | head -10
echo '-- ixsmi --'; ixsmi 2>&1 | head -20
echo '-- corex 库 --'; ls /opt/corex-host 2>/dev/null | head -5
" 2>&1 | head -50

  echo "== 10. 内核日志尾部 =="
  journalctl -k --no-pager -n 40 2>/dev/null | tail -40 || dmesg 2>/dev/null | tail -40

  echo "== 11. 驱动安装包是否在手边 =="
  ls -l /home/qch/transfer/corex-driver-linux64-5.0.0_aarch64.run 2>/dev/null || echo "transfer 无 .run"
  find /home -maxdepth 3 -name "corex-driver*run" 2>/dev/null | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
