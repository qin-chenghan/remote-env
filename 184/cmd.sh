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
  # 修正：DKMS 从源目录 /usr/src/corex-5.0.0 拷贝 dkms.conf，改源目录那份。
  # 关闭 vGPU（6.6 无 CONFIG_VFIO_MDEV）-> 重编 -> 安装 -> 加载 -> 验证。

  K=$(uname -r)
  SRC=/usr/src/corex-5.0.0
  CONF=$SRC/dkms.conf

  echo "== 0. 源 dkms.conf 现状 =="
  grep -n "_BUILDOPT\|VGPU_ENABLE" "$CONF" 2>/dev/null || { echo "missing $CONF"; exit 1; }

  echo "== 1. 改源目录 dkms.conf =="
  cp -a "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"
  if grep -q "VGPU_ENABLE=1" "$CONF"; then
    sed -i 's/VGPU_ENABLE=1/VGPU_ENABLE=0/g' "$CONF"
    echo "VGPU_ENABLE set to 0 (source)"
    grep -n "VGPU_ENABLE" "$CONF"
  else
    echo "VGPU_ENABLE=1 not found in source conf; abort"
    exit 1
  fi

  echo "== 2. Kbuild 里 vGPU 检查的开关条件 =="
  grep -n -B10 -A6 "vgpu_kvm_sanity_check" "$SRC/itr/Kbuild" 2>/dev/null | head -40

  echo "== 3. dkms build =="
  dkms build corex/5.0.0 -k "$K" 2>&1 | tail -30
  RC=${PIPESTATUS[0]}
  echo "build rc=$RC"
  if [ "$RC" -ne 0 ]; then
    echo "== build 失败，make.log 尾部 =="
    tail -120 /var/lib/dkms/corex/5.0.0/build/make.log 2>/dev/null
    exit 1
  fi

  echo "== 4. dkms install =="
  dkms install corex/5.0.0 -k "$K" 2>&1 | tail -20
  RC=${PIPESTATUS[0]}
  echo "install rc=$RC"
  if [ "$RC" -ne 0 ]; then
    exit 1
  fi

  echo "== 5. depmod + modprobe =="
  depmod -a
  modprobe iluvatar 2>&1
  echo "modprobe rc=$?"
  lsmod | grep iluvatar || echo "iluvatar NOT loaded"
  ls -l /dev/iluvatar* 2>&1 | head -10

  echo "== 6. 验证 =="
  dmesg | tail -20
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | head -20
  dkms status

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
