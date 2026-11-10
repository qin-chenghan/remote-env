#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 任务：为当前 64K 内核编译并安装 iluvatar 驱动（不回退内核）。
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
  K=$(uname -r)
  echo "kernel=$K"

  echo "== provenance =="
  cat /proc/cmdline
  ls -la "/lib/modules/$K" 2>&1 | head -12
  echo "build -> $(readlink -f "/lib/modules/$K/build" 2>&1)"
  echo "source -> $(readlink -f "/lib/modules/$K/source" 2>&1)"
  rpm -qf "/lib/modules/$K" 2>&1
  rpm -qa | grep -iE '^kernel' | sort | head -20

  echo "== build headers present? =="
  if [ -f "/lib/modules/$K/build/Makefile" ]; then
    echo "BUILD_DIR_OK"
  else
    echo "BUILD_DIR_MISSING"
    dnf list --available 'kernel-devel*' 2>&1 | tail -12
    dnf list --installed 'kernel-devel*' 2>&1 | tail -8
    echo "== ABORT: 没有匹配的 build 头文件，需先装 kernel-devel, 不强装 =="
    exit 6
  fi

  echo "== dkms.conf guard =="
  grep -n '_BUILDOPT' /usr/src/corex-5.0.0/dkms.conf
  sed -i 's/_BUILDOPT="VGPU_ENABLE=1 "/_BUILDOPT="VGPU_ENABLE=0 "/' /usr/src/corex-5.0.0/dkms.conf
  grep -n '_BUILDOPT="VGPU' /usr/src/corex-5.0.0/dkms.conf | head -2

  echo "== dkms build =="
  dkms build corex/5.0.0 -k "$K" 2>&1 | tail -30
  echo "build rc=${PIPESTATUS[0]}"

  echo "== dkms install =="
  dkms install corex/5.0.0 -k "$K" 2>&1 | tail -30
  echo "install rc=${PIPESTATUS[0]}"

  echo "== dkms status =="
  dkms status 2>&1 | head -10

  echo "== modules on disk =="
  find "/lib/modules/$K" -name 'iluvatar*.ko*' 2>/dev/null | head -10

  echo "== depmod + modprobe =="
  depmod -a "$K" 2>&1
  modprobe iluvatar 2>&1; echo "modprobe rc=$?"
  lsmod | grep -iE 'iluvatar' || echo "  still not loaded"

  echo "== devices / dmesg =="
  ls -l /dev/iluvatar* 2>&1
  dmesg 2>/dev/null | grep -iE 'iluvatar|corex' | tail -15

  echo "== dkms service =="
  systemctl enable --now dkms 2>&1 | tail -3
  systemctl is-enabled dkms 2>&1

  echo "== ixsmi =="
  ixsmi 2>&1 | head -20

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
