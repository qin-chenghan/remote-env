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

  echo "== 1. torch fastpath 安装记录 =="
  docker exec corex5-py311 /opt/corex311/bin/pip show torch-module-attr-fastpath 2>&1 | head -6

  echo "== 2. torch fastpath 状态（venv 干净 sys.path）=="
  docker exec -e PYTHONPATH= -e TORCH_MODULE_ATTR_FASTPATH=slot_native corex5-py311 \
    /opt/corex311/bin/python3 -c \
    "import torch, torch_module_attr_fastpath as m; print('torch:', torch.__version__, torch.__file__); print(m.status())"

  echo "== 3. 容器默认 PYTHONPATH 下会加载到哪个 torch（预期失败/3.12）=="
  docker exec -e TORCH_MODULE_ATTR_FASTPATH=slot_native corex5-py311 \
    /opt/corex311/bin/python3 -c \
    "import torch; print(torch.__file__)" 2>&1 | tail -4

  echo "== 4. 容器默认 env =="
  docker exec corex5-py311 sh -c 'echo PYTHONPATH=${PYTHONPATH:-<empty>}; echo LD_PRELOAD=${LD_PRELOAD:-<empty>}'

  echo "== 5. 当前 vLLM 进程环境（是否已带 torch fastpath）=="
  for p in $(pgrep -f vllm.entrypoints.openai.api_server 2>/dev/null); do
    echo "-- PID $p --"
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null \
      | grep -E 'PYTHONPATH|TORCH_MODULE_ATTR_FASTPATH|VLLM_HOST_FASTPATH|HOTSPOT_OPT' || true
  done

  echo "== 6. 压测/服务进程 =="
  pgrep -af 'vllmBench_lite_opt.sh|bench_driver.py' 2>/dev/null | head -10 || true

  echo "== 7. transfer 目录（看 hotspot wheel 是否已上传）=="
  ls -l /home/qch/transfer 2>/dev/null | tail -20

  echo "== 8. r3 host fastpath 安装自检 =="
  if [ -d /home/qch/transfer/vllm-dev-host-opt-validation-r3-arm64-py311-py312-20261103 ]; then
    docker exec corex5-py311 bash -lc 'ls /opt/corex311/lib/python3.11/site-packages | grep -i host_opt || true'
  else
    echo "r3 目录不在 /home/qch/transfer（可能已移走，跳过）"
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
