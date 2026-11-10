#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读诊断：184 重启后 iluvatar 驱动失效。
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
  echo "== os / kernel =="
  head -2 /etc/os-release
  uname -r
  uptime
  echo "installed kernels:"
  ls -1 /lib/modules/ 2>&1

  echo "== module state =="
  lsmod | grep -iE 'iluvatar|corex' || echo "  no iluvatar module loaded"
  ls -l /dev/iluvatar* 2>&1
  modinfo iluvatar 2>&1 | head -8

  echo "== built modules on disk =="
  find /lib/modules -name 'iluvatar*.ko*' 2>/dev/null | head -10
  echo "-- current kernel dir --"
  ls -la "/lib/modules/$(uname -r)/extra" 2>&1 | head -10

  echo "== dkms =="
  dkms status 2>&1 | head -10
  ls -la /var/lib/dkms/corex 2>&1 | head -8

  echo "== dkms.conf BUILDOPT =="
  grep -n '_BUILDOPT' /usr/src/corex-5.0.0/dkms.conf 2>&1

  echo "== kernel-devel =="
  rpm -q "kernel-devel-$(uname -r)" 2>&1
  ls -d /usr/src/kernels/* 2>&1

  echo "== dmesg (driver) =="
  dmesg 2>/dev/null | grep -iE 'iluvatar|corex' | tail -20

  echo "== try modprobe (no-op check) =="
  modprobe -n iluvatar 2>&1; echo "modprobe -n rc=$?"

  echo "== ixsmi =="
  ixsmi 2>&1 | head -12

  echo "== services =="
  systemctl list-units --type=service 2>/dev/null | grep -iE 'iluvatar|corex|dkms' | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
