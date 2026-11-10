#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：追查 64K 内核的构建位置 / devel 产物。
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
  echo "== builder shell history =="
  grep -iE 'make|rpmbuild|64k|kernel|6\.6' /home/l30029702/.bash_history 2>&1 | tail -30

  echo "== root history =="
  grep -iE '64k|02403|make .*kernel|modules_prepare' /root/.bash_history 2>&1 | tail -20

  echo "== broad search for devel/02403 =="
  find / -xdev -iname 'kernel-devel*6.6.02403*' 2>/dev/null | head -5
  find / -xdev -maxdepth 6 \( -iname '*02403*' -o -iname '*_64K*' \) 2>/dev/null | grep -vE '^/proc|^/sys' | head -15

  echo "== docker overlay kernel sources =="
  ls -d /home/docker/overlay2/*/diff/usr/src/linux* 2>/dev/null | head -5
  ls -d /home/docker/overlay2/*/merged/usr/src/linux* 2>/dev/null | head -5

  echo "== containers =="
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1 | head -10

  echo "== rpm output dirs =="
  ls -d /root/rpmbuild/RPMS/* /home/*/rpmbuild/RPMS/* 2>/dev/null | head -5
  find /home/l30029702 -maxdepth 3 -type d 2>/dev/null | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
