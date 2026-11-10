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
  SRC=/tmp/corex-drv/kernel

  echo "== 1. 编译 iluvatar.ko（在 tmpfs 上，不写 /）=="
  cd "$SRC" || exit 1
  make KERNEL_UNAME="$K" -j"$(nproc)" > /tmp/corex-build.log 2>&1
  RC=$?
  echo "build rc=$RC"
  tail -30 /tmp/corex-build.log
  KO=$(find "$SRC" -name 'iluvatar.ko' -type f 2>/dev/null | head -1)
  echo "ko path=$KO"

  if [ "$RC" -eq 0 ] && [ -n "$KO" ]; then
    echo "== 2. 模块信息 =="
    ls -l "$KO"
    file "$KO"
    modinfo "$KO" 2>/dev/null | grep -E '^(version|vermagic|name|license|depends)' | head -6

    echo "== 3. 安装模块 =="
    install -D -m 644 "$KO" "/lib/modules/$K/updates/iluvatar.ko"
    echo "install rc=$?"
    ls -l "/lib/modules/$K/updates/iluvatar.ko"
    echo iluvatar > /etc/modules-load.d/iluvatar.conf
    df -h / | tail -1

    echo "== 4. depmod + modprobe =="
    depmod -a "$K"
    echo "depmod rc=$?"
    modprobe iluvatar
    echo "modprobe rc=$?"
    lsmod | grep iluvatar || echo "iluvatar NOT loaded"
    ls -l /dev/iluvatar* 2>&1 | head -6

    echo "== 5. 内核日志 =="
    dmesg 2>/dev/null | grep -iE 'iluvatar|version magic|module verification' | tail -15

    echo "== 6. ixsmi =="
    timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | head -25
  else
    echo "!! 编译失败或无 .ko，未安装。查看 /tmp/corex-build.log"
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
