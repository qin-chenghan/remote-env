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
  # 只读：解析旧 docker 数据目录的元数据，确认 corex5-py311 镜像是否还在。

  echo "== 1. 旧库体积与结构 =="
  du -sh /home/docker 2>/dev/null
  du -sh /home/docker/* 2>/dev/null | sort -rh | head -10
  ls /home/docker/image/overlay2/imagedb/content/sha256 2>/dev/null | wc -l
  ls /home/docker/overlay2 2>/dev/null | wc -l

  echo "== 2. 旧库镜像标签（解析 imagedb 元数据）=="
  python3 - <<'PY'
import glob, json, os
for root in ('/home/docker', '/data-hdd/docker'):
    d = root + '/image/overlay2/imagedb/content/sha256'
    files = glob.glob(d + '/*')
    print(f"---- {root}: {len(files)} images")
    for p in files:
        try:
            j = json.load(open(p))
        except Exception:
            continue
        tags = j.get('RepoTags') or []
        if tags:
            print('  ', os.path.basename(p)[:12], tags)
PY

  echo "== 3. 旧库里的容器 =="
  python3 - <<'PY'
import glob, json
for root in ('/home/docker', '/data-hdd/docker'):
    print(f"---- {root}")
    for p in glob.glob(root + '/containers/*/config.v2.json'):
        try:
            j = json.load(open(p))
        except Exception:
            continue
        print('  ', j.get('Name'), '|', j.get('Config', {}).get('Image'),
              '| created', j.get('Created', '')[:19])
PY

  echo "== 4. 定向搜索 corex 相关元数据 =="
  grep -rl 'corex5-py311' /home/docker/image/overlay2/imagedb/content/sha256 2>/dev/null | head -5
  grep -rl 'corex5-py311' /home/docker/containers 2>/dev/null | head -5
  grep -rl 'corex' /data-hdd/docker/image/overlay2/imagedb/content/sha256 2>/dev/null | head -5

  echo "== 5. overlay2 最大的几个层 =="
  du -sh /home/docker/overlay2/* 2>/dev/null | sort -rh | head -10

  echo "== 6. 当前 daemon 与旧库对比 =="
  docker info 2>&1 | grep -iE 'Docker Root Dir|Images:|Containers:'
  docker images 2>&1 | grep -iE 'corex|vllm' || echo "当前 daemon 无 corex 镜像"

  echo "== 7. GPU 与内核 =="
  uname -r
  ls -l /dev/iluvatar* 2>&1 | head -5
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'BI-V150|MiB /' | head -6

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
