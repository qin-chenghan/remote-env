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
  K=$(uname -r)
  RUN=/home/qch/transfer/corex-driver-linux64-5.0.0_x86_64.run

  echo "== 1. 解包驱动到 tmpfs（不写 /）=="
  X=/tmp/corex-drv
  rm -rf "$X"
  sh "$RUN" --noexec --keep --target "$X" 2>&1 | tail -5
  find "$X" -maxdepth 2 2>/dev/null | head -25
  echo "-- dkms.conf 的 vGPU 开关 --"
  grep -nE 'VGPU_ENABLE|_BUILDOPT|MAKE\[0\]' "$X/kernel/dkms.conf" 2>/dev/null | head -10
  echo "-- 安装脚本支持的内核参数 --"
  grep -nE 'KERNEL_ONLY|NO_KERNEL|--kernel|VGPU|silent|silent_option' "$X/corex-driver-installer" 2>/dev/null | head -15

  echo "== 2. 清理缓存腾空间 =="
  df -h / | tail -1
  dnf clean all 2>&1 | tail -3
  journalctl --vacuum-size=100M 2>&1 | tail -2
  df -h / | tail -1
  AVAIL=$(df -m / | awk 'NR==2{print $4}')
  echo "avail_mb=$AVAIL"

  echo "== 3. dkms 仓库可见性 =="
  timeout 60 dnf list available dkms 2>&1 | tail -5

  if [ "$AVAIL" -lt 2000 ]; then
    echo "!! 可用空间不足 2000MB，跳过安装。需要先清理 / 。"
  else
    echo "== 4. 安装与运行内核匹配的 kernel-devel + dkms =="
    timeout 300 dnf install -y "kernel-devel-$K" dkms 2>&1 | tail -25
    echo "install rc=$?"

    echo "== 5. 验证 =="
    ls -ld "/lib/modules/$K/build" 2>&1
    readlink -f "/lib/modules/$K/build" 2>&1
    command -v dkms && dkms --version
    echo "-- 内核 VFIO 配置（判断是否需要关 vGPU）--"
    grep -E 'CONFIG_VFIO_MDEV|CONFIG_VFIO=|CONFIG_VFIO_GROUP' "/usr/src/kernels/$K/.config" 2>/dev/null | head -5
    df -h / | tail -1
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
