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
  # 只读：确认 OS/内核现状，以及每个内核下 iluvatar.ko 是否齐备。

  echo "== 1. OS 与当前内核 =="
  head -5 /etc/os-release
  uname -r
  getconf PAGE_SIZE
  grubby --default-kernel 2>&1
  grub2-editenv list 2>&1

  echo "== 2. 已装内核包 =="
  rpm -qa 2>/dev/null | grep -E '^kernel(-devel|-headers|-tools|-source)?-' | sort

  echo "== 3. grub 候选 =="
  grubby --info=ALL 2>/dev/null | grep -E 'index=|kernel=' | head -20

  echo "== 4. 每个内核的 iluvatar.ko 与 vermagic =="
  for k in /lib/modules/*; do
    KN=$(basename "$k")
    if [ -f "$k/updates/iluvatar.ko" ]; then
      echo "[$KN] updates/iluvatar.ko $(stat -c %s "$k/updates/iluvatar.ko") bytes vermagic=$(modinfo -F vermagic "$k/updates/iluvatar.ko" 2>&1 | tr -d '\n')"
    elif [ -f "$k/kernel/drivers/misc/iluvatar.ko" ]; then
      echo "[$KN] kernel/.../iluvatar.ko $(stat -c %s "$k/kernel/drivers/misc/iluvatar.ko") bytes vermagic=$(modinfo -F vermagic "$k/kernel/drivers/misc/iluvatar.ko" 2>&1 | tr -d '\n')"
    else
      echo "[$KN] 无 iluvatar.ko"
    fi
    ls -d "$k/build" >/dev/null 2>&1 && echo "     build 目录存在" || echo "     build 目录缺失"
  done

  echo "== 5. 当前驱动 =="
  lsmod | grep iluvatar || echo "未加载"
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'BI-V150|MiB /' | head -6

  echo "== 6. docker 根的两处配置 =="
  cat /etc/docker/daemon.json
  ls -ld /home/docker /data-ssd/docker
  du -sh /home/docker 2>/dev/null
  ls /home/docker/image/overlay2/imagedb/content/sha256 2>/dev/null | wc -l

  echo "== 7. 旧库中 corex 容器的镜像引用 =="
  python3 - <<'PY'
import glob, json
for p in glob.glob('/home/docker/containers/*/config.v2.json'):
    try:
        j = json.load(open(p))
    except Exception:
        continue
    name = j.get('Name', '')
    if 'corex' in name or 'vllm' in name:
        print(name, '| image', j.get('Config', {}).get('Image'), '| created', j.get('Created', '')[:19])
PY

  echo "== 8. 空间 =="
  df -h / /home /data-ssd /data-hdd 2>/dev/null | tail -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
