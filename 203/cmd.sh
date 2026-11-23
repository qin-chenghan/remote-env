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
  # 只读：用 diff_ids 校验 corex 镜像层，以及旧库 layerdb → overlay2 的链接完整性。

  echo "== 1. corex5-py311 镜像配置 =="
  python3 - <<'PY'
import json, os
pid = '438486a0cac34c0f6802d9af065b2e9ca67b7ef1ec9504f0b2432d108e1c9fb1'
p = f'/home/docker/image/overlay2/imagedb/content/sha256/{pid}'
print('exists:', os.path.exists(p))
j = json.load(open(p))
rf = j.get('rootfs', {})
print('type:', rf.get('type'))
diffs = rf.get('diff_ids') or rf.get('layers') or []
print('layer_count:', len(diffs))
print('docker_version:', j.get('docker_version'))
print('created:', j.get('created'))
print('first_diff:', diffs[0] if diffs else None)
PY

  echo "== 2. 旧库 layerdb → overlay2 链接校验 =="
  python3 - <<'PY'
import glob, os
lb = '/home/docker/image/overlay2/layerdb/sha256'
ov = '/home/docker/overlay2'
entries = glob.glob(lb + '/*')
missing_cache = []
no_cache_id = 0
for e in entries:
    cid = os.path.join(e, 'cache-id')
    if not os.path.exists(cid):
        no_cache_id += 1
        continue
    val = open(cid).read().strip()
    if not os.path.isdir(os.path.join(ov, val)):
        missing_cache.append((os.path.basename(e)[:12], val))
print('layerdb_entries:', len(entries))
print('overlay2_dirs:', len([d for d in os.listdir(ov) if not d.endswith('-init')]))
print('without_cache_id:', no_cache_id)
print('missing_overlay_dirs:', len(missing_cache))
for m in missing_cache[:10]:
    print('  ', m)
PY

  echo "== 3. 旧库里每个容器的镜像是否都能解析 =="
  python3 - <<'PY'
import glob, json, os
imagedb = '/home/docker/image/overlay2/imagedb/content/sha256'
names = set(os.path.basename(p) for p in glob.glob(imagedb + '/*'))
ok = miss = 0
for p in glob.glob('/home/docker/containers/*/config.v2.json'):
    j = json.load(open(p))
    img = (j.get('Config', {}).get('Image') or '').replace('sha256:', '')
    if img in names:
        ok += 1
    else:
        miss += 1
        print('  MISSING image for container', j.get('Name'), img[:16])
print(f'containers_with_image={ok} missing={miss}')
PY

  echo "== 4. /home 空间与 inode =="
  df -h /home | tail -1
  df -i /home | tail -1
  du -sh /home/docker 2>/dev/null

  echo "== 5. 旧库是否被占用（无进程应持有）=="
  fuser -vm /home/docker 2>&1 | head -5 || echo "no holder"
  ls /home/docker/*.pid /run/docker*.pid 2>/dev/null

  echo "== 6. 当前 e2b/harbor 是否在活跃使用 =="
  docker ps --format '{{.Names}}\t{{.Status}}' 2>&1
  echo "-- 最近日志写入时间 --"
  for c in harbor-core harbor-db registry postgres; do
    docker inspect -f '{{.Name}} started={{.State.StartedAt}} restarts={{.RestartCount}}' "$c" 2>/dev/null
  done
  docker logs --tail 5 harbor-core 2>&1 | tail -5

  echo "== 7. 当前 daemon 与 GPU =="
  docker info 2>&1 | grep -iE 'Docker Root Dir|Containers|Images'
  uname -r
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'BI-V150|MiB /' | head -6

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
