#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 任务：查 corex5-py311 未启动原因，启动并验证 GPU 栈。
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
  echo "== container state before =="
  docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} policy={{.HostConfig.RestartPolicy.Name}}' corex5-py311 2>&1

  echo "== start it =="
  docker start corex5-py311 2>&1
  echo "start rc=$?"

  sleep 6

  echo "== container state after =="
  docker ps --format '{{.Names}}\t{{.Status}}' 2>&1 | head -3
  docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}}' corex5-py311 2>&1

  echo "== container logs tail =="
  docker logs --tail 20 corex5-py311 2>&1 | tail -20

  echo "== devices =="
  docker exec corex5-py311 bash -c 'ls -l /dev/iluvatar* 2>&1 | head -6' 2>&1

  echo "== ixsmi =="
  docker exec corex5-py311 ixsmi 2>&1 | sed -n '1,14p'

  echo "== venv imports =="
  for V in /opt/corex311 /opt/corex311-cpython-vllm; do
    docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME "$V/bin/python3" -c \
      "import torch,vllm;print('$V ok',torch.__version__,vllm.__version__)" 2>&1 | tail -2
  done

  echo "== r10 files =="
  docker exec corex5-py311 bash -c 'ls /opt/corex311/lib/python3.11/site-packages/vllm/v1/worker/host_opt.py /opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm/v1/worker/host_opt.py 2>&1' 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
