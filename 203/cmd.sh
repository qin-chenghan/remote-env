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
  # 只读诊断：ixsmi 找不到，区分是 PATH/符号链接问题还是驱动掉了。

  echo "== 1. PATH 与二进制 =="
  echo "PATH=$PATH"
  command -v ixsmi || echo "ixsmi 不在 PATH"
  ls -l /usr/local/corex/bin/ixsmi /usr/local/corex-5.0.0/bin/ixsmi /usr/local/corex-4.4.0/bin/ixsmi 2>&1
  ls -ld /usr/local/corex /usr/local/corex-5.0.0 /usr/local/corex-4.4.0 2>&1
  readlink -f /usr/local/corex 2>&1
  ls /usr/local/corex 2>&1 | head

  echo "== 2. 当前内核 =="
  uname -r
  uname -m
  getconf PAGE_SIZE
  ls /lib/modules 2>&1
  rpm -qa 2>/dev/null | grep -E '^kernel(-devel|-headers)?-' | sort

  echo "== 3. 模块状态 =="
  lsmod | grep iluvatar || echo "iluvatar 未加载"
  for k in /lib/modules/*; do
    ls -l "$k/updates/iluvatar.ko" 2>/dev/null
    ls -l "$k/kernel/drivers/misc/iluvatar.ko" 2>/dev/null
  done
  modinfo -F vermagic /lib/modules/"$(uname -r)"/updates/iluvatar.ko 2>&1
  cat /etc/modules-load.d/iluvatar.conf 2>&1
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null || echo "無参数文件"

  echo "== 4. 设备节点 =="
  ls -l /dev/iluvatar* 2>&1 | head -6

  echo "== 5. 尝试加载 =="
  modprobe iluvatar 2>&1
  echo "modprobe rc=$?"
  lsmod | grep iluvatar || echo "仍未加载"
  ls -l /dev/iluvatar* 2>&1 | head -6

  echo "== 6. 内核日志 =="
  dmesg 2>/dev/null | grep -iE 'iluvatar|version magic|unknown symbol|module verification' | tail -20

  echo "== 7. ixsmi 直跑 =="
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | head -25
  echo "ixsmi rc=$?"

  echo "== 8. 重启历史 =="
  uptime
  last -x reboot 2>/dev/null | head -5

  echo "== 9. 容器内 ixsmi =="
  docker exec corex5-py311 bash -lc '
    command -v ixsmi || echo "容器内无 ixsmi"
    ls /usr/local/corex/bin 2>&1 | head -8
    ls /dev/iluvatar* 2>&1 | wc -l
  ' 2>&1 | head -15

  echo "== 10. 空间 =="
  df -h / /home | tail -3

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
