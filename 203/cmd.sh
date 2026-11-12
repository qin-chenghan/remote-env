#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 203 根盘数字对不上账：df 全表、挂载点、保留块、du -x 对账、近期增长来源。
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
  echo "== 1. 全部挂载与 df =="
  df -h
  echo "--- 具体设备 ---"
  findmnt -T / -o TARGET,SOURCE,FSTYPE,OPTIONS
  findmnt -T /data -o TARGET,SOURCE,FSTYPE 2>/dev/null
  findmnt -T /usr/local -o TARGET,SOURCE,FSTYPE 2>/dev/null
  lsblk 2>/dev/null | head -20

  echo "== 2. 空间去哪了：Used + Avail + Reserved =="
  df -B1 /
  echo "--- 文件系统保留块 ---"
  fs=$(findmnt -no FSTYPE /)
  dev=$(findmnt -no SOURCE /)
  echo "fs=$fs dev=$dev"
  if [ "$fs" = ext4 ] || [ "$fs" = ext3 ]; then
    tune2fs -l "$dev" 2>/dev/null | grep -iE 'Block count|Free blocks|Reserved block count|Block size|Filesystem features' | head -6
  elif [ "$fs" = xfs ]; then
    xfs_info "$dev" 2>/dev/null | head -10
    xfs_db -r -c 'freesp -s' "$dev" 2>/dev/null | head -10
  fi

  echo "== 3. du 对账（-x 不跨挂载点）=="
  du -xsh / 2>/dev/null
  echo "--- 不跨挂载点的一层 ---"
  du -xsh /* 2>/dev/null | sort -rh | head -12
  echo "--- /data 是否独立设备 ---"
  du -sh /data 2>/dev/null
  du -xsh /data 2>/dev/null
  echo "--- /usr/local 是否独立设备 ---"
  du -sh /usr/local 2>/dev/null
  du -xsh /usr/local 2>/dev/null

  echo "== 4. swap =="
  swapon --show 2>/dev/null || echo "无 swap 设备"
  find / -xdev -maxdepth 2 -name '*swap*' -size +1G 2>/dev/null | head -5

  echo "== 5. 近两天根盘上新增长的大文件/目录 =="
  find / -xdev -type f -mtime -2 -size +50M 2>/dev/null | head -20 | while read -r f; do du -h "$f"; done
  echo "--- /var/log 近两天 ---"
  find /var/log -type f -mtime -2 -size +10M 2>/dev/null | head -10 | while read -r f; do du -h "$f"; done

  echo "== 6. 可直接回收项汇总（当前实测）=="
  for p in /opt/maca-3.3.0 /usr/local/corex-4.4.0 /usr/src/linux-6.6.0-72.0.0.76.oe2403sp1.x86_64 /var/cache/dnf /var/log /boot; do
    [ -e "$p" ] && du -sh "$p"
  done
  journalctl --disk-usage 2>/dev/null
  echo "--- 是否有人引用 corex-4.4.0 / maca ---"
  grep -rIl 'corex-4.4.0' /etc/profile.d /root/.bashrc /etc/ld.so.conf.d /usr/local/bin 2>/dev/null | head -5 || true
  ls -l /usr/local/corex /usr/local/corex-5.0.0 2>/dev/null | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
