#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 203 根盘满：只读盘点可回收项（不清任何东西）。
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
  echo "== 1. 根盘现状 =="
  df -h /
  df -i / | tail -1

  echo "== 2. / 一层目录占用（排除挂载点）=="
  for d in /usr /var /opt /data /root /etc /srv /tmp /boot; do
    [ -d "$d" ] && du -sh "$d" 2>/dev/null
  done
  echo "--- /usr 二层 ---"
  du -sh /usr/* 2>/dev/null | sort -rh | head -8
  echo "--- /var 二层 ---"
  du -sh /var/* 2>/dev/null | sort -rh | head -8
  echo "--- /opt 二层 ---"
  du -sh /opt/* 2>/dev/null | sort -rh | head -8
  echo "--- /root 二层 ---"
  du -sh /root/* 2>/dev/null | sort -rh | head -8

  echo "== 3. 候选可回收项 =="
  du -sh /var/cache/dnf 2>/dev/null
  du -sh /var/log 2>/dev/null
  journalctl --disk-usage 2>/dev/null
  du -sh /usr/src/* 2>/dev/null | sort -rh | head -5
  du -sh /opt/maca /opt/maca-3.3.0 /usr/local/corex-4.4.0 /usr/local/corex-5.0.0 2>/dev/null
  du -sh /data/log 2>/dev/null
  ls -l /lib/modules 2>/dev/null

  echo "== 4. 已装内核与可删旧内核 =="
  rpm -q kernel kernel-devel kernel-source kernel-headers 2>/dev/null | head -20
  echo "--- /usr/src 里的 kernel 源 ---"
  ls -d /usr/src/linux-* 2>/dev/null
  echo "--- 当前内核 / 默认启动内核 ---"
  uname -r
  grubby --default-kernel 2>/dev/null || echo "no grubby"
  echo "--- /boot ---"
  du -sh /boot 2>/dev/null
  ls -lt /boot 2>/dev/null | head -8

  echo "== 5. 大文件（>200M，根盘，跳过挂载点）=="
  find / -xdev -type f -size +200M 2>/dev/null | head -25 | while read -r f; do
    du -h "$f" 2>/dev/null
  done

  echo "== 6. docker =="
  docker info 2>/dev/null | grep -E 'Docker Root Dir|Storage Driver'
  timeout 60 docker system df 2>&1 | head -8

  echo "== 7. 是否有进程仍持有已删大文件 =="
  lsof +D / 2>/dev/null | grep -i deleted | head -10 || echo "lsof 无输出或无权限"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
