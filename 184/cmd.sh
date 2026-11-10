#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：对比 11-09 那次编译用的 devel 树，并判断 64K 内核能否复用同样套路。
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
  echo "== /usr/src/kernels =="
  ls -la /usr/src/kernels 2>&1

  echo "== 11-09 那次的 devel 树 =="
  D=/usr/src/kernels/6.6.0-145.3.37.168.oe2403sp3.aarch64
  ls -l "$D/Module.symvers" "$D/.config" "$D/include/generated/asm-offsets.h" 2>&1
  rpm -qf "$D/Module.symvers" 2>&1
  head -3 "$D/.config" 2>&1

  echo "== 5.10 64K 的 devel 树（同名套路参照） =="
  ls -d /usr/src/kernels/*64k* /usr/src/kernels/*64K* 2>&1
  ls -l /usr/src/kernels/5.10.0-225.0.0.124.oe2203sp4.aarch64+64kb/Module.symvers 2>&1

  echo "== 64K 内核是否要求 MODVERSIONS =="
  grep -E '^CONFIG_MODVERSIONS|^CONFIG_MODULE_SIG|^CONFIG_ARM64_64K_PAGES' \
    /boot/config-6.6.02403_sp3-64K 2>&1

  echo "== 145 内核同类配置对照 =="
  grep -E '^CONFIG_MODVERSIONS|^CONFIG_ARM64_64K_PAGES' \
    /boot/config-6.6.0-145.3.37.168.oe2403sp3.aarch64 2>&1

  echo "== 当前 64K 内核已有的模块 vermagic 参照 =="
  f=$(find /lib/modules/6.6.02403_sp3-64K -name '*.ko' 2>/dev/null | head -1)
  echo "sample=$f"
  [ -n "$f" ] && modinfo -F vermagic "$f" 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
