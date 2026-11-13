#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 184 SP4 双内核（4K 159.4.21.175 / 64K 159.4.3.154）驱动现状盘点（只读）。
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
  echo "== 1. 当前运行内核 =="
  uname -a
  uname -r
  getconf PAGE_SIZE
  echo "--- 最近重启 ---"
  last -x reboot 2>/dev/null | head -5

  echo "== 2. /lib/modules 与各内核 build 目录 =="
  ls -l /lib/modules
  for k in $(ls /lib/modules); do
    echo "---- $k"
    ls -ld "/lib/modules/$k/build" 2>&1
    readlink -f "/lib/modules/$k/build" 2>/dev/null
    ls -ld "/lib/modules/$k/updates" 2>&1
    find "/lib/modules/$k" -name 'iluvatar*.ko' 2>/dev/null | head -5
  done

  echo "== 3. 内核配置（64K 与 VFIO_MDEV）=="
  for k in $(ls /lib/modules); do
    cfg="/boot/config-$k"
    [ -f "$cfg" ] || cfg="/lib/modules/$k/config"
    echo "---- $k"
    grep -E 'CONFIG_ARM64_(4K|16K|64K)_PAGES|CONFIG_VFIO_MDEV|CONFIG_MODULES' "$cfg" 2>/dev/null | head -5
  done

  echo "== 4. grub 启动项 =="
  grubby --default-kernel 2>&1
  grubby --info=ALL 2>/dev/null | grep -E '^index|^kernel=|^title' | head -30
  grub2-editenv list 2>/dev/null | head -5

  echo "== 5. DKMS 与驱动源码 =="
  command -v dkms && dkms --version 2>&1
  dkms status 2>&1 | head -20
  ls -la /usr/src/ 2>/dev/null | head -10
  ls -la /usr/src/corex-5.0.0 2>/dev/null | head -15
  echo "--- dkms.conf 关键项 ---"
  grep -nE '_BUILDOPT|PACKAGE_NAME|PACKAGE_VERSION|MAKE' /usr/src/corex-5.0.0/dkms.conf 2>/dev/null | head -10
  echo "--- cfg.mk 的 VGPU_ENABLE ---"
  grep -rn 'VGPU_ENABLE' /usr/src/corex-5.0.0/itr/cfg.mk 2>/dev/null | head -5
  echo "--- /var/lib/dkms ---"
  ls -la /var/lib/dkms/corex 2>/dev/null | head -15
  find /var/lib/dkms/corex -maxdepth 3 -name '*.ko' 2>/dev/null | head -10

  echo "== 6. 已装模块与 vermagic =="
  for f in $(find /lib/modules -name 'iluvatar.ko' 2>/dev/null); do
    echo "---- $f"
    modinfo -F vermagic "$f" 2>/dev/null
    ls -l "$f"
  done

  echo "== 7. 运行时状态 =="
  lsmod 2>/dev/null | grep -i iluvatar || echo "iluvatar 未加载"
  ls -l /dev/iluvatar* 2>/dev/null | head -10 || echo "无 /dev/iluvatar*"
  ls -l /etc/modules-load.d/ 2>/dev/null | head -5
  /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | head -12 || echo "ixsmi 不可用"
  dmesg -T 2>/dev/null | grep -iE 'iluvatar|corex|vermagic' | tail -15

  echo "== 8. 驱动安装包与工具链 =="
  ls -l /home/qch/transfer/corex-driver-*aarch64*.run /home/qch/transfer/corex-driver*.run 2>/dev/null | head -5
  find /home /tmp -maxdepth 3 -name 'iluvatar.ko' -newermt '-30 days' 2>/dev/null | head -5
  gcc --version 2>/dev/null | head -1
  make --version 2>/dev/null | head -1

  echo "== 9. rpm 库与内核包 =="
  rpm -qa 'kernel*' 2>&1 | sort
  echo "--- rpmdb 健康状况 ---"
  rpm -qa > /dev/null 2>/tmp/rpmdb-err.txt; grep -c 'skipping h#' /tmp/rpmdb-err.txt 2>/dev/null; head -5 /tmp/rpmdb-err.txt 2>/dev/null
  ls -la /var/lib/rpm/ 2>/dev/null | head -8

  echo "== 10. 空间 =="
  df -h / /home /tmp | tail -4

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
