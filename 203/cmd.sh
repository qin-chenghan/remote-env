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
  echo "== 1. 宿主机 GPU 状态 =="
  lsmod | grep iluvatar
  ls /dev/iluvatar* | wc -l
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null || echo "no multi_engine param"

  echo "== 2. 容器设备配置 =="
  docker inspect corex5-py311 --format '{{json .HostConfig.Devices}}' 2>&1 | head -5
  docker inspect corex5-py311 --format '{{json .HostConfig.DeviceRequests}}' 2>&1 | head -5
  docker inspect corex5-py311 --format '{{range .HostConfig.Binds}}{{.}}{{"\n"}}{{end}}' 2>&1 | head -10
  docker inspect corex5-py311 --format '{{.State.StartedAt}}' 2>&1

  echo "== 3. 容器内是否看到 GPU =="
  docker exec corex5-py311 bash -lc '
    echo -n "devices: "; ls /dev/iluvatar* 2>/dev/null | wc -l
    ixsmi -L 2>&1 | head -8
  ' 2>&1 | head -20

  echo "== 4. 容器内 venv 与包 =="
  docker exec corex5-py311 bash -lc '
    ls /opt 2>/dev/null
    for p in /opt/corex311/bin/python /opt/corex311-cpython-vllm/bin/python; do
      [ -x "$p" ] && echo "$p -> $("$p" -V 2>&1)"
    done
    /opt/corex311/bin/pip list 2>/dev/null | grep -iE "^(vllm|torch|ixsys|triton|transformers)"
  ' 2>&1 | head -30

  echo "== 5. 容器内 corex =="
  docker exec corex5-py311 bash -lc 'ls /usr/local | head -10; echo "COREX_VERSION=${COREX_VERSION:-<empty>}"' 2>&1 | head -15

  echo "== 6. 空间 =="
  df -h / | tail -1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
