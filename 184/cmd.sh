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
  # 只读：确认旧内核与驱动模块、grub 候选、驱动安装来源、服务状态。
  # 不 reboot、不 insmod、不装包。

  echo "== 1. grub 默认与候选 =="
  grubby --default-kernel 2>/dev/null || echo "grubby 不可用"
  echo "-- 所有内核条目 --"
  grubby --info=ALL 2>/dev/null | grep -E "index=|kernel=|title=" | head -40
  echo "-- /boot 下的内核 --"
  ls -1 /boot/vmlinuz* /boot/Image* 2>/dev/null | head -20

  echo "== 2. 各内核下的 iluvatar.ko =="
  find /lib/modules -name "iluvatar.ko*" -printf "%p\n" 2>/dev/null | head -10
  for d in /lib/modules/*/; do
    k=$(basename "$d")
    if [ -e "$d/kernel/drivers/misc/iluvatar.ko" ]; then echo "HAS_MODULE $k"; fi
  done

  echo "== 3. 驱动来源（包/安装器）=="
  rpm -qa 2>/dev/null | grep -iE "corex|iluvatar" | head -20 || echo "rpm 无匹配"
  echo "-- /usr/local/corex-5.0.0 --"
  ls -la /usr/local/corex-5.0.0 2>/dev/null | head -12
  echo "-- 驱动安装器搜索 --"
  timeout 60 find /root /opt /usr/local /home /var -maxdepth 5 \
    \( -name "*corex*driver*" -o -name "*.run" -o -name "*iluvatar*.ko" \) 2>/dev/null \
    | grep -iE "corex|iluvatar|driver" | head -20

  echo "== 4. 服务状态 =="
  systemctl list-units --all 2>/dev/null | grep -iE "iluvatar|corex" | head -10 || echo "无相关 unit"
  systemctl status iluvatarcorex-init 2>&1 | head -15 || true
  systemctl status "iluvatarcorex-init*" 2>&1 | head -15 || true
  journalctl -u iluvatarcorex-init --no-pager -n 30 2>/dev/null | tail -30 || true

  echo "== 5. 新内核的 headers/devel =="
  rpm -qa 2>/dev/null | grep -E "kernel-devel|kernel-headers" | head -10
  ls /usr/src/kernels 2>/dev/null | head -10

  echo "== 6. 容器重启策略 =="
  docker inspect corex5-py311 --format 'RestartPolicy={{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || true

  echo "== 7. 页面大小 =="
  getconf PAGESIZE 2>/dev/null || true

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
