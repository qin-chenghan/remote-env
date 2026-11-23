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
  # 只读：切换 data-root 到 /home/docker 前的可行性核查。

  echo "== 1. 当前 daemon 与配置 =="
  docker version --format '{{.Server.Version}}' 2>&1
  docker info 2>&1 | grep -iE 'Docker Root Dir|Storage Driver|Images|Containers|Running'
  cat /etc/docker/daemon.json
  systemctl show docker -p ExecStart -p FragmentPath 2>&1 | head -5

  echo "== 2. 当前 daemon 里在跑什么（切换会停掉这些）=="
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1 | head -20
  echo "-- 容器数 --"
  docker ps -q 2>&1 | wc -l

  echo "== 3. 旧库结构完整性 =="
  ls -ld /home/docker
  for p in image/overlay2/imagedb/content/sha256 image/overlay2/imagedb/metadata/sha256 image/overlay2/layerdb/sha256 overlay2 containers volumes network engine-id; do
    if [ -e "/home/docker/$p" ]; then
      printf '%-45s %s\n' "$p" "$(ls "/home/docker/$p" 2>/dev/null | wc -l)"
    else
      printf '%-45s MISSING\n' "$p"
    fi
  done
  ls /home/docker/image/overlay2/repositories.json 2>&1

  echo "== 4. 旧库容器状态（元数据）=="
  python3 - <<'PY'
import glob, json, os
running = 0
total = 0
for p in glob.glob('/home/docker/containers/*/config.v2.json'):
    try:
        j = json.load(open(p))
    except Exception:
        continue
    total += 1
    name = j.get('Name', '?')
    img = j.get('Config', {}).get('Image', '?')
    st = j.get('State', {})
    if st.get('Running'):
        running += 1
    print(f"{name:32s} running={st.get('Running')} status={st.get('Status')} image={str(img)[:60]}")
print(f"total={total} running_at_save_time={running}")
PY

  echo "== 5. corex5-py311 的镜像与层是否齐 =="
  python3 - <<'PY'
import glob, json, os
tgt = 'sha256:438486a0cac34c0f6802d9af065b2e9ca67b7ef1ec9504f0b2432d108e1c9fb1'
p = '/home/docker/image/overlay2/imagedb/content/sha256/' + tgt.split(':')[1]
print('imagedb exists:', os.path.exists(p))
if os.path.exists(p):
    j = json.load(open(p))
    rootfs = j.get('rootfs', {}).get('layers', [])
    print('layers:', len(rootfs))
    missing = []
    for i, d in enumerate(rootfs):
        lp = '/home/docker/image/overlay2/layerdb/sha256/' + d.split(':')[1]
        if not os.path.exists(lp):
            missing.append(i)
    print('missing layerdb entries:', missing if missing else 'none')
    ds = j.get('docker_version')
    print('docker_version:', ds)
PY

  echo "== 6. 旧库最后一次写入时间 =="
  stat -c '%y %n' /home/docker /home/docker/containers 2>&1
  ls -lt /home/docker/containers | head -3

  echo "== 7. 空间 =="
  df -h /home /data-ssd /data-hdd /data-ext4 2>/dev/null | tail -5
  du -sh /home/docker 2>/dev/null

  echo "== 8. GPU 就绪度（切完要能起 corex5-py311）=="
  uname -r
  ls -l /dev/iluvatar* 2>&1 | head -5
  lsmod | grep iluvatar
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'BI-V150|MiB /' | head -6

  echo "== 9. 有没有别的服务依赖 /home/docker 或 e2b 栈 =="
  systemctl list-units --type=service --state=running 2>/dev/null | grep -iE 'harbor|nomad|consul|e2b|docker' | head -10
  ls /data-ssd/harbor /data-ssd/nomad 2>&1 | head -8

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
