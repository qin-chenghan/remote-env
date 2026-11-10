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
  # 只读：为 6.6 内核重装 iluvatar 5.0.0 驱动做前置调查。不执行 .run、不 insmod、不 reboot。

  echo "== 1. 内核与 OS =="
  uname -r
  uname -m
  head -4 /etc/os-release
  getconf PAGESIZE

  echo "== 2. 驱动安装器 =="
  find /home /opt /usr/local /root -maxdepth 4 -name 'corex-driver*' 2>/dev/null | head -10
  for f in $(find /home /opt /usr/local /root -maxdepth 4 -name 'corex-driver*.run' 2>/dev/null | head -5); do
    ls -l "$f"; sha256sum "$f"; file "$f"
  done

  echo "== 3. 内核头文件/构建目录 =="
  ls -d /lib/modules/$(uname -r)/build 2>&1
  ls -ld /lib/modules/$(uname -r)/build 2>&1
  readlink -f /lib/modules/$(uname -r)/build 2>&1
  ls -d /usr/src/kernels/* 2>/dev/null | head -10
  rpm -qa 2>/dev/null | grep -E 'kernel-devel|kernel-headers|kernel-source' | head -10

  echo "== 4. DKMS 现状 =="
  command -v dkms && dkms --version
  dkms status 2>&1 | head -10
  ls -la /var/lib/dkms/corex/5.0.0 2>&1 | head -10
  ls -d /usr/src/corex* 2>&1 | head

  echo "== 5. 源 dkms.conf 的 vGPU 开关 =="
  grep -n 'VGPU_ENABLE|_BUILDOPT|MAKE\[0\]' /usr/src/corex-5.0.0/dkms.conf 2>/dev/null || \
    grep -nE '_BUILDOPT|MAKE\[0\]' /usr/src/corex-5.0.0/dkms.conf 2>/dev/null || echo "no /usr/src/corex-5.0.0/dkms.conf"
  ls /usr/src/corex-5.0.0/itr/Kbuild 2>/dev/null && \
    grep -n -A3 'BUILD_SANITY_CHECKS' /usr/src/corex-5.0.0/itr/Kbuild | head -10

  echo "== 6. 旧内核模块与用户态 =="
  find /lib/modules -name 'iluvatar.ko*' 2>/dev/null | head -10
  ls -d /usr/local/corex* /usr/local/iluvatar* 2>/dev/null
  ls /usr/local/corex-5.0.0/bin 2>/dev/null | head -8
  cat /usr/local/corex-5.0.0/version 2>/dev/null || true

  echo "== 7. 模块自动加载配置 =="
  cat /etc/modules-load.d/iluvatar.conf 2>/dev/null
  grep -rn iluvatar /etc/modprobe.d/ 2>/dev/null | head -5

  echo "== 8. 编译工具 =="
  for c in gcc g++ make dkms ld xz; do printf '%s: ' "$c"; command -v "$c" || echo missing; done
  gcc --version 2>/dev/null | head -1
  nproc

  echo "== 9. 磁盘余量（dkms 构建需要空间）=="
  df -h / /var /home /usr/src 2>&1
  echo "-- /var/lib/dkms 占用 --"
  du -sh /var/lib/dkms 2>/dev/null
  echo "-- / 上占用最大的目录 --"
  du -xhd1 / 2>/dev/null | sort -rh | head -10

  echo "== 10. grub 候选 =="
  grubby --default-kernel 2>/dev/null || echo "grubby 不可用"
  grubby --info=ALL 2>/dev/null | grep -E 'index=|kernel=' | head -20

  echo "== 11. 加速卡 PCI 与厂商 =="
  lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display|accelerator|processing|iluvatar|metax|nvidia' | head -20

  echo "== 12. 上一次启动的驱动错误 =="
  dmesg 2>/dev/null | grep -iE 'iluvatar|version magic|module verification|mdev|vfio' | tail -15 || echo "无"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
