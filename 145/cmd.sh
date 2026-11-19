#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。为搬运 aarch64 天数镜像做准备：docker 落盘/容量、已有镜像、SELinux/文件系统、
#       以及“独立 dockerd（data-root 放 /home）”方案的可行性。
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

  echo "== 1. docker 落盘与容量 =="
  docker info 2>&1 | grep -iE "Docker Root Dir|Storage Driver|Server Version|Cgroup Driver" | head -6
  ROOT=$(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print $2}')
  echo "root=$ROOT"
  df -h "$ROOT" 2>/dev/null | tail -1
  echo "-- 已有容器的数量与运行状态 --"
  docker ps -q | wc -l; docker ps -a -q | wc -l
  du -sh "$ROOT" 2>/dev/null | tail -1

  echo "== 2. /home 文件系统与权限 =="
  stat -f -c '%n %T blocks=%b bsize=%S' /home 2>/dev/null
  df -h /home | tail -1
  ls -ld /home /home/qch
  echo "-- SELinux --"
  command -v getenforce >/dev/null 2>&1 && getenforce || echo "no getenforce"
  ls /etc/selinux/config 2>/dev/null && grep -E "^SELINUX=" /etc/selinux/config

  echo "== 3. 已有镜像（找 aarch64 天数/corex 镜像）=="
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' 2>&1 | head -25
  docker images 2>/dev/null | grep -iE "corex|iluvatar|ixrt|天数|bi-v" | head -10

  echo "== 4. 本地是否已有镜像 tar / 迁移包 =="
  ls -la /home/qch/transfer 2>/dev/null | head -15
  ls -lh /home/qch/*.tar /home/qch/*.tar.gz /home/qch/transfer/*.tar* 2>/dev/null | head -10
  du -sh /home/qch/transfer 2>/dev/null

  echo "== 5. 宿主是否已装天数 userspace SDK（无内核模块也应该有这套）=="
  ls -d /usr/local/corex-5.0.0 /usr/local/corex* 2>&1 | head -5
  ls /usr/local/corex-5.0.0/lib 2>/dev/null | head -8
  rpm -qa 2>/dev/null | grep -iE "corex|iluvatar|ixrt" | head -10
  lsmod 2>/dev/null | grep -i iluvatar || echo "no iluvatar module"
  ls -l /dev/iluvatar* 2>&1 | head -3

  echo "== 6. 独立 dockerd 方案可行性（不动现有 daemon）=="
  command -v dockerd; dockerd --version 2>&1 | head -1
  systemctl is-active docker 2>&1
  ls -l /etc/docker/daemon.json 2>/dev/null && cat /etc/docker/daemon.json
  ls -l /var/run/docker.sock
  echo "-- sudo 免密？ --"
  sudo -n true 2>&1 && echo "sudo-nopasswd OK" || echo "sudo 需要密码或无权限"
  echo "-- /home 可用空间（镜像 28G，解开约 35-40G）--"
  df -h /home | tail -1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
