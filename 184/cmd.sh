#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：对比升级前后内核日志里 iluvatar 告警的出现情况，判断是否 SP4 驱动引入。不跑测试。
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
  echo "== 1. export_refcount 告警按日统计（升级前 11-12 vs 升级后 11-13）=="
  journalctl -k --since '2026-11-09' --no-pager 2>/dev/null | grep -c 'export_refcount'
  echo "--- 按日期 ---"
  journalctl -k --since '2026-11-09' --no-pager 2>/dev/null | grep 'export_refcount' | awk '{print $1" "$2}' | sort | uniq -c
  echo "--- 首次出现 ---"
  journalctl -k --since '2026-11-09' --no-pager 2>/dev/null | grep 'export_refcount' | head -3
  echo "--- 升级前最后出现（11-12 23:59 之前）---"
  journalctl -k --until '2026-11-13 00:00' --no-pager 2>/dev/null | grep 'export_refcount' | tail -3

  echo "== 2. 各次启动以来 iluvatar 相关内核消息（分类计数）=="
  journalctl -k --since '2026-11-09' --no-pager 2>/dev/null | grep -i iluvatar | sed -E 's/^[A-Za-z]+ [ 0-9]+ [0-9:]+ .*kernel: //' | sed -E 's/[0-9]{6,}/N/g' | sort | uniq -c | sort -rn | head -15

  echo "== 3. 11-13 当天所有内核 warning 以上（去重分类）=="
  journalctl -k --since '2026-11-13 09:30' --no-pager -p warning 2>/dev/null | sed -E 's/^[A-Za-z]+ [ 0-9]+ [0-9:]+ [^ ]+ kernel: //' | sort | uniq -c | sort -rn | head -15

  echo "== 4. 压测期间是否有其他进程占用 GPU（从 journal 里找）=="
  journalctl --since '2026-11-13 10:15' --until '2026-11-13 11:40' --no-pager 2>/dev/null | grep -iE 'ixsmi|iluvatar|gpu|ixformer|ptrace|segfault|coredump|killed' | tail -30

  echo "== 5. 4K 驱动构建来源（谁、何时、基于哪份头文件）=="
  ls -l --time-style=full-iso /lib/modules/6.6.0-159.4.21.175.oe2403sp4.aarch64/updates/ 2>/dev/null
  dkms status
  ls -l --time-style=full-iso /var/lib/dkms/corex/5.0.0/*/*/module/ 2>/dev/null | head -10

  echo "== 6. 两个内核的驱动哈希对比 =="
  for k in 6.6.0-159.4.21.175.oe2403sp4.aarch64 6.6.0-159.4.3.154.oe2403sp4+64k.aarch64; do
    f=/lib/modules/$k/updates/iluvatar.ko.xz
    [ -f "$f" ] && { echo -n "$k  "; ls -l "$f" | awk '{print $5" "$6" "$7" "$8}'; xzcat "$f" 2>/dev/null | sha256sum; }
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
