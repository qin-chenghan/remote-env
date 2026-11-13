#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：核对 10:00-11:40 期间系统做了什么（装包/模块/网络/服务），不跑测试。
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
  C=corex5-py311
  dex() { timeout 60 docker exec "$C" bash -c "$1"; }

  echo "== 1. 升级/装包时间线（按安装时间排序）=="
  rpm -qa --last 2>/dev/null | head -30
  echo "--- kernel 相关包的安装时间 ---"
  rpm -qa --last 'kernel*' 2>/dev/null | head -10

  echo "== 2. 10:00-11:40 的系统告警日志 =="
  journalctl --since '2026-11-13 10:00' --until '2026-11-13 11:45' -p warning --no-pager 2>/dev/null | tail -60

  echo "== 3. 该时段的 dnf/rpm/内核模块/网络事件 =="
  journalctl --since '2026-11-13 09:30' --until '2026-11-13 11:45' --no-pager 2>/dev/null \
    | grep -iE 'dnf|rpm|yum|kernel|modprobe|iluvatar|NetworkManager|nic|link|carrier|tcp|oom' | tail -40

  echo "== 4. 机器启动与重启记录 =="
  uptime
  last -x reboot 2>/dev/null | head -5

  echo "== 5. 内核树与模块目录的时间戳 =="
  ls -lat --time-style=long-iso /usr/src/kernels | head -6
  ls -lat --time-style=long-iso /lib/modules | head -6

  echo "== 6. 容器内 venv 是否在 10:47 前后被动过 =="
  dex "ls -lat --time-style=long-iso /opt/corex311-cpython-vllm | head -8; ls -lat --time-style=full-iso /opt/corex311-cpython-vllm/lib/python3.11/site-packages | head -5"

  echo "== 7. 10:19-11:35 容器内是否有别的活动（文件系统变更）=="
  dex "find /opt/corex311-cpython-vllm -newermt '2026-11-13 10:00' ! -newermt '2026-11-13 12:00' -type f 2>/dev/null | head -20; echo '--- count ---'; find /opt/corex311-cpython-vllm -newermt '2026-11-13 10:00' ! -newermt '2026-11-13 12:00' -type f 2>/dev/null | wc -l"

  echo "== 8. 关键 sysctl（网络/文件句柄类）=="
  sysctl net.core.somaxconn net.ipv4.ip_local_port_range net.ipv4.tcp_syncookies fs.file-max 2>/dev/null
  ulimit -n

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
