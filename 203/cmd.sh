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
  # Docker data-root 回切：/data-ssd/docker -> /home/docker（仅重启 dockerd，不重启机器）。

  CUR=/etc/docker/daemon.json
  BAK=/etc/docker/daemon.json.bak-$TS
  OLDROOT=/data-ssd/docker
  NEWROOT=/home/docker
  SNAP=/home/qch/docker-state-before-$TS.txt

  echo "== 1. 切前快照 =="
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "$SNAP" 2>&1
  wc -l "$SNAP"
  cp -a "$CUR" "$BAK"
  echo "daemon.json 备份: $BAK"
  cat "$CUR"
  df -h /home | tail -1

  echo "== 2. 修改 data-root =="
  python3 - "$CUR" "$NEWROOT" <<'PY'
import json, sys
p, newroot = sys.argv[1], sys.argv[2]
j = json.load(open(p))
print("old data-root:", j.get("data-root"))
j["data-root"] = newroot
json.dump(j, open(p, "w"), indent=2)
print("new data-root:", j.get("data-root"))
PY
cat "$CUR"

  echo "== 3. 重启 dockerd =="
  systemctl restart docker
  echo "restart rc=$?"
  sleep 5
  systemctl is-active docker
  docker info 2>&1 | grep -iE 'Docker Root Dir|Storage Driver|Images:|Containers:'

  echo "== 4. 验证旧库镜像 =="
  docker images 2>&1 | head -25
  echo "-- corex 相关 --"
  docker images 2>&1 | grep -iE 'corex|vllm' | head -10
  echo "-- 容器 --"
  docker ps -a --format '{{.Names}}\t{{.Status}}' 2>&1 | head -20

  echo "== 5. 启动 corex5-py311 =="
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | sed -n '/Processes/,$p' | head -8
  docker start corex5-py311 2>&1
  echo "start rc=$?"
  sleep 5
  docker ps --filter name=corex5-py311 --format '{{.Names}}\t{{.Status}}'

  echo "== 6. 容器内 GPU 验证 =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 \
    /opt/corex311/bin/python -c 'import torch;print("devices",torch.cuda.device_count())' 2>&1 | tail -3
  docker exec corex5-py311 bash -lc 'ls /dev/iluvatar* 2>/dev/null | wc -l' 2>&1

  echo "== 7. 空间与状态 =="
  df -h /home | tail -1
  docker info 2>&1 | grep -iE 'Containers:|Running:|Images:'

  echo "== 8. 回滚命令 =="
  echo "cp $BAK $CUR && systemctl restart docker"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
