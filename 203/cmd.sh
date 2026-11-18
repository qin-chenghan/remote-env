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
  # 内核升级到 6.6.0-159 后重建 iluvatar.ko（kernel-devel 已装）。

  K=$(uname -r)
  RUN=/home/qch/transfer/corex-driver-linux64-5.0.0_x86_64.run
  SRC=/home/qch/transfer/corex-drv-5.0.0-x86_64

  echo "== 1. 前置 =="
  echo "kernel=$K"
  ls -ld "/lib/modules/$K/build" 2>&1
  readlink -f "/lib/modules/$K/build" 2>&1
  df -h / /home | tail -2

  echo "== 2. 解包驱动（持久化到 /home，供后续内核升级复用）=="
  if [ ! -d "$SRC/kernel" ]; then
    rm -rf "$SRC"
    sh "$RUN" --noexec --keep --target "$SRC" 2>&1 | tail -4
  else
    echo "已存在，复用 $SRC"
  fi
  ls "$SRC" 2>&1 | head -8

  echo "== 3. 编译 =="
  cd "$SRC/kernel" || exit 1
  make KERNEL_UNAME="$K" -j"$(nproc)" > "$SRC/build-$K.log" 2>&1
  RC=$?
  echo "build rc=$RC"
  tail -20 "$SRC/build-$K.log"
  KO="$SRC/kernel/iluvatar.ko"

  if [ "$RC" -eq 0 ] && [ -f "$KO" ]; then
    echo "== 4. 安装模块 =="
    install -D -m 644 "$KO" "/lib/modules/$K/updates/iluvatar.ko"
    echo "install rc=$?"
    modinfo -F vermagic "/lib/modules/$K/updates/iluvatar.ko" 2>&1

    echo "== 5. depmod + modprobe =="
    depmod -a "$K"
    modprobe iluvatar
    echo "modprobe rc=$?"
    lsmod | grep iluvatar || echo "仍未加载"
    ls -l /dev/iluvatar* 2>&1 | head -6

    echo "== 6. 验证 =="
    dmesg 2>/dev/null | grep -iE 'iluvatar' | tail -10
    timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | head -20
    echo "ixsmi rc=$?"
  else
    echo "!! 编译失败，未安装。日志: $SRC/build-$K.log"
  fi

  echo "== 7. 收尾 =="
  df -h / | tail -1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
