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
  # 只读：确认能否补齐 kernel-devel(132) 与 dkms，以及磁盘上可回收的空间。

  echo "== 1. 挂载与全部磁盘 =="
  df -hT 2>/dev/null | head -20

  echo "== 2. / 上的空间分布 =="
  du -xhd2 /usr /opt /root /data /var 2>/dev/null | sort -rh | head -40

  echo "== 3. docker 占用 =="
  docker system df 2>&1 | head -10

  echo "== 4. transfer 目录内容 =="
  ls -la /home/qch/transfer 2>&1 | head -30
  find /home/qch/transfer -maxdepth 2 -name '*.rpm' 2>/dev/null | head -20

  echo "== 5. 本地是否有 132 的 kernel-devel rpm =="
  find /home /data /opt /root -maxdepth 5 -name 'kernel-devel-6.6*132*' -o -maxdepth 5 -name 'kernel-devel*.rpm' 2>/dev/null | head -20

  echo "== 6. 已装/可见的内核包 =="
  rpm -qa 2>/dev/null | grep -E '^kernel' | sort | head -20

  echo "== 7. dnf 仓库 =="
  ls /etc/yum.repos.d/ 2>&1 | head -10
  timeout 90 dnf repolist 2>&1 | tail -20

  echo "== 8. dnf 能否提供 132 的 kernel-devel 与 dkms =="
  timeout 120 dnf list --showduplicates 'kernel-devel*' 'dkms' 2>&1 | tail -30
  echo "-- 精确到运行内核 --"
  timeout 120 dnf info "kernel-devel-$(uname -r)" 2>&1 | head -15

  echo "== 9. 旧内核目录与 build =="
  ls /lib/modules/ 2>&1
  ls -ld /usr/src/kernels/* 2>/dev/null
  ls /usr/src/kernels/6.6.0-72.0.0.76.oe2403sp1.x86_64 2>/dev/null | head -5

  echo "== 10. 驱动包里是否有 kernel 源码/预编译模块 =="
  strings /home/qch/transfer/corex-driver-linux64-5.0.0_x86_64.run 2>/dev/null \
    | grep -aoE '(dkms|VGPU_ENABLE|kernel/[a-z]+|corex-[0-9.]+|prebuilt|ko)' | sort | uniq -c | head -20

  echo "== 11. 当前是否已有容器占用 GPU / 有无残留进程 =="
  docker ps --format '{{.Names}}\t{{.Status}}' 2>&1 | head -10
  ps -eo pid,args 2>/dev/null | grep -E 'vllm|ixsmi' | grep -v grep | cut -c1-160 | head -5

  echo "== 12. 网络与代理 =="
  env | grep -iE 'proxy|no_proxy' || echo "无 proxy 环境变量"
  timeout 10 ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && echo "外网 ping 通" || echo "外网 ping 不通"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
