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
  # 6.6 内核没有 CONFIG_VFIO_MDEV：先把 DKMS 的 VGPU_ENABLE 改 0，再重编/安装/加载。
  # 只动当前内核的模块；不重装用户态、不重启、不动旧内核模块。失败即停。

  K=$(uname -r)
  CONF=/var/lib/dkms/corex/5.0.0/build/dkms.conf

  echo "== 0. 当前内核与 DKMS 参数 =="
  echo "kernel=$K"
  grep -n "VGPU_ENABLE\|_BUILDOPT\|MAKE\[0\]" "$CONF" 2>/dev/null || { echo "dkms.conf missing"; exit 1; }

  echo "== 1. 关闭 vGPU 构建（备份 dkms.conf）=="
  cp -a "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"
  if grep -q "VGPU_ENABLE=1" "$CONF"; then
    sed -i 's/VGPU_ENABLE=1/VGPU_ENABLE=0/g' "$CONF"
    echo "VGPU_ENABLE set to 0"
    grep -n "VGPU_ENABLE" "$CONF"
  else
    echo "VGPU_ENABLE=1 not found; abort"
    exit 1
  fi

  echo "== 2. dkms build =="
  dkms build corex/5.0.0 -k "$K" 2>&1 | tail -30
  RC=${PIPESTATUS[0]}
  echo "build rc=$RC"
  if [ "$RC" -ne 0 ]; then
    echo "== build 失败，make.log 尾部 =="
    tail -120 /var/lib/dkms/corex/5.0.0/build/make.log 2>/dev/null
    exit 1
  fi

  echo "== 3. dkms install =="
  dkms install corex/5.0.0 -k "$K" 2>&1 | tail -20
  RC=${PIPESTATUS[0]}
  echo "install rc=$RC"
  if [ "$RC" -ne 0 ]; then
    exit 1
  fi

  echo "== 4. depmod + modprobe =="
  depmod -a
  modprobe iluvatar 2>&1
  echo "modprobe rc=$?"
  lsmod | grep iluvatar || echo "iluvatar NOT loaded"
  ls -l /dev/iluvatar* 2>&1 | head -10

  echo "== 5. 验证 =="
  dmesg | tail -20
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | head -20
  dkms status

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
