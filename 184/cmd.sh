#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 184 为 64K SP4 内核编装 iluvatar 驱动；4K 已装好，不动它。
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
  K64=6.6.0-159.4.3.154.oe2403sp4+64k.aarch64
  K4K=6.6.0-159.4.21.175.oe2403sp4.aarch64
  SRC=/usr/src/corex-5.0.0

  echo "== 1. 前置：运行内核与 64K build 树 =="
  uname -r
  ls -ld /lib/modules/$K64/build
  ls -l /usr/src/kernels/$K64/Makefile /usr/src/kernels/$K64/include/generated/autoconf.h 2>&1
  ls -d /usr/src/kernels/$K64/scripts 2>&1
  grep -E '^CONFIG_ARM64_64K_PAGES' /boot/config-$K64 2>/dev/null
  echo "--- 源码与编译参数 ---"
  grep -n '_BUILDOPT' $SRC/dkms.conf
  df -h / | tail -1

  echo "== 2. 当前安装状态（记录基线）=="
  dkms status 2>&1
  ls -ld /lib/modules/$K64/updates 2>&1
  find /lib/modules/$K64 -name 'iluvatar.ko*' 2>/dev/null | head -5
  lsmod | grep -i iluvatar

  echo "== 3. 编译 64K 模块（耗时几分钟）=="
  timeout 1500 dkms build corex/5.0.0 -k $K64 2>&1 | tail -40
  BUILD_RC=${PIPESTATUS[0]}
  echo "dkms build rc=$BUILD_RC"

  if [ "$BUILD_RC" -eq 0 ]; then
    echo "== 4. 安装 64K 模块 =="
    timeout 600 dkms install corex/5.0.0 -k $K64 2>&1 | tail -20
    INSTALL_RC=${PIPESTATUS[0]}
    echo "dkms install rc=$INSTALL_RC"
  else
    echo "编译失败，跳过安装；日志见 /var/lib/dkms/corex/5.0.0/build/ 与 $SRC"
  fi

  echo "== 5. 落盘核对 =="
  dkms status 2>&1
  ls -ld /lib/modules/$K64/updates 2>&1
  find /lib/modules/$K64 -name 'iluvatar.ko*' 2>/dev/null | head -5
  for f in $(find /lib/modules/$K64 -name 'iluvatar.ko*' 2>/dev/null | head -2); do
    echo "---- $f"
    ls -l "$f"
    modinfo -F vermagic "$f" 2>/dev/null
  done
  echo "--- depmod（对全部内核刷新依赖）---"
  depmod -a 2>&1 | tail -5; echo "depmod rc=$?"

  echo "== 6. 复核 4K 侧未受影响 =="
  ls -l /lib/modules/$K4K/updates 2>&1 | head -5
  dkms status 2>&1 | grep "$K4K"
  lsmod | grep -i iluvatar
  /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'MiB /' | head -4

  echo "== 7. 启动项现状（不要凭空重启）=="
  grubby --default-kernel
  grub2-editenv list 2>/dev/null | head -3

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
