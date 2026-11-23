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
  # 只读：切 OS 后容器/镜像是否还在其它磁盘路径。

  echo "== 1. 主机与内核 =="
  hostname
  uname -r
  getconf PAGE_SIZE
  head -3 /etc/os-release
  uptime

  echo "== 2. 磁盘与挂载 =="
  df -hT 2>/dev/null | head -25
  lsblk 2>/dev/null | head -30

  echo "== 3. docker 配置与状态 =="
  systemctl is-active docker 2>&1
  systemctl is-enabled docker 2>&1
  cat /etc/docker/daemon.json 2>&1
  docker info 2>&1 | grep -iE 'Docker Root Dir|Storage Driver|Images:|Containers:|Server Version' | head -8

  echo "== 4. 当前 docker 可见内容 =="
  docker images 2>&1 | head -20
  docker ps -a 2>&1 | head -20

  echo "== 5. 候选 docker 数据目录 =="
  for d in /var/lib/docker /data-ssd/docker /data/docker /home/docker /mnt/docker /opt/docker /var/lib/containerd; do
    if [ -e "$d" ]; then
      echo "--- $d"
      ls -ld "$d" 2>&1
      du -sh "$d" 2>/dev/null
      ls "$d" 2>&1 | head -8
    fi
  done

  echo "== 6. 找 overlay2 / docker 目录（限深度）=="
  find / -maxdepth 4 -type d -name overlay2 2>/dev/null | head -10
  find / -maxdepth 3 -type d -name docker 2>/dev/null | grep -v '^/proc' | head -10

  echo "== 7. data-ssd 与其它数据盘内容 =="
  ls -la /data-ssd 2>&1 | head -20
  du -sh /data-ssd/* 2>/dev/null | sort -rh | head -15
  ls -la /data 2>&1 | head -15

  echo "== 8. 镜像 tar / 备份 =="
  find /home /data /data-ssd /opt -maxdepth 4 \( -name '*.tar' -o -name '*.tar.gz' \) -size +50M 2>/dev/null | head -10

  echo "== 9. 仓库与 transfer =="
  ls -l /home/qch/tools/remote-env 2>&1 | head -5
  ls /home/qch 2>&1 | head -10
  ls /home/qch/transfer 2>&1 | head -10

  echo "== 10. GPU 驱动状态 =="
  lsmod | grep iluvatar || echo "iluvatar 未加载"
  ls /lib/modules 2>&1
  ls -l /dev/iluvatar* 2>&1 | head -5
  modinfo -F vermagic /lib/modules/"$(uname -r)"/updates/iluvatar.ko 2>&1

  echo "== 11. 空间 =="
  du -xhd1 / 2>/dev/null | sort -rh | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
