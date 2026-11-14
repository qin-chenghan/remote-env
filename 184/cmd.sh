#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：排查内核切换为什么没生效（grubenv/EFI grub.cfg/菜单标题/启动记录）。
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
  echo "== 1. 当前内核与启动记录 =="
  uname -r
  getconf PAGE_SIZE
  uptime
  last -x reboot 2>/dev/null | head -6

  echo "== 2. grubby 视角 =="
  grubby --default-kernel
  grubby --info=ALL 2>/dev/null | grep -E '^index|^kernel=|^title' | head -20

  echo "== 3. grubenv 全部内容（重点 recordfail / boot_success / saved_entry）=="
  grub2-editenv list 2>/dev/null
  ls -l /boot/grub2/grubenv 2>/dev/null

  echo "== 4. 是否记录过失败启动 =="
  grub2-editenv - list 2>/dev/null | grep -E 'recordfail|boot_success' || echo "无相关字段"

  echo "== 5. /etc/default/grub =="
  cat /etc/default/grub 2>/dev/null

  echo "== 6. 实际被读取的 grub.cfg（BIOS 路径与 EFI 路径都要看）=="
  ls -l /boot/grub2/grub.cfg 2>/dev/null
  ls -l /boot/efi/EFI/*/grub.cfg 2>/dev/null
  echo "--- EFI 目录 ---"
  ls -R /boot/efi/EFI 2>/dev/null | head -20

  echo "== 7. grub.cfg 里的 default/saved 逻辑与菜单项 =="
  grep -nE '^\s*(set default|set saved_entry|if \[|menuentry)' /boot/grub2/grub.cfg 2>/dev/null | head -25
  echo "--- EFI grub.cfg 同样字段 ---"
  for f in /boot/efi/EFI/*/grub.cfg; do [ -f "$f" ] && { echo "## $f"; grep -nE '^\s*(set default|set saved_entry|if \[|menuentry)' "$f" | head -15; }; done

  echo "== 8. 当前内核项在菜单里的标题 =="
  grubby --info="$(grubby --default-kernel)" 2>/dev/null | head -6

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
