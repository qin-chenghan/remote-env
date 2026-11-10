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
  X=/tmp/corex-drv

  echo "== 1. 安装器形态 =="
  file "$X/corex-driver-installer" 2>&1
  if file "$X/corex-driver-installer" | grep -q ELF; then
    strings "$X/corex-driver-installer" 2>/dev/null | grep -iE -- '--?(kernel|silent|vGPU|force|uninstall)[a-z-]*' | sort -u | head -20
  else
    sed -n '1,40p' "$X/corex-driver-installer" 2>&1
  fi

  echo "== 2. VGPU 默认值与 sanity check =="
  grep -rnI VGPU_ENABLE "$X/kernel" 2>/dev/null | head -15
  grep -n -B4 -A8 'BUILD_SANITY_CHECKS' "$X/kernel/itr/Kbuild" 2>/dev/null | head -25

  echo "== 3. kernel/Makefile 目标 =="
  grep -nE '^[a-zA-Z0-9_./-]+:|KERNEL_UNAME|MODULE|install' "$X/kernel/Makefile" 2>/dev/null | head -25

  echo "== 4. firmware 是否已装 =="
  ls -l /lib/firmware/iluvatar_cp.bin 2>&1
  ls "$X/firmware" 2>/dev/null

  echo "== 5. 空间评估（先不删旧内核源码）=="
  du -sh /usr/src /usr/src/kernels 2>/dev/null
  rpm -q kernel-source 2>&1
  df -h / | tail -1

  echo "== 6. 安装匹配运行内核的 kernel-devel =="
  timeout 300 dnf install -y "kernel-devel-$K" 2>&1 | tail -20
  echo "install rc=$?"
  df -h / | tail -1

  echo "== 7. 验证 build 目录与 VFIO 配置 =="
  ls -ld "/lib/modules/$K/build" 2>&1
  readlink -f "/lib/modules/$K/build" 2>&1
  grep -E 'CONFIG_VFIO_MDEV' "/usr/src/kernels/$K/.config" 2>/dev/null | head -3
  df -h / | tail -1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
