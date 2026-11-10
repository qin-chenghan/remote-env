#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读；宿主机执行，/opt 属于容器，走 docker exec。
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
  echo "== 3.12 tree packages (transformers?) =="
  docker exec corex5-py311 bash -c 'ls -d /usr/local/lib/python3.12/site-packages/transformers-*.dist-info 2>&1; ls -d /usr/local/lib/python3.12/site-packages/vllm-*.dist-info 2>&1'

  echo "== reproduce: pip list with polluted env =="
  docker exec -e PYTHONPATH=/usr/local/lib/python3.12/site-packages corex5-py311 \
    /opt/corex311/bin/python3 -m pip list 2>&1 | grep -E '^(transformers|vllm|torch) ' | head -10

  echo "== same, clean env =="
  docker exec -e PYTHONPATH= corex5-py311 \
    /opt/corex311/bin/python3 -m pip list 2>&1 | grep -E '^(transformers|vllm|torch) ' | head -10

  echo "== which transformers actually imports =="
  docker exec -e PYTHONPATH=/usr/local/lib/python3.12/site-packages corex5-py311 \
    /opt/corex311/bin/python3 -c "import transformers;print('polluted ->',transformers.__version__,transformers.__file__)" 2>&1 | tail -3
  docker exec -e PYTHONPATH= corex5-py311 \
    /opt/corex311/bin/python3 -c "import transformers;print('clean ->',transformers.__version__,transformers.__file__)" 2>&1 | tail -3

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
