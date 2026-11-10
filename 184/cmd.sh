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
  MARK='# 184: strip container-level PYTHONPATH pollution'

  echo "== patch venv activate (idempotent) =="
  for V in /opt/corex311 /opt/corex311-cpython-vllm; do
    A="$V/bin/activate"
    echo "-- $A"
    if grep -q "$MARK" "$A" 2>/dev/null; then
      echo "  already patched"
    else
      cp -a "$A" "$A.bak-pyenv-$TS" 2>/dev/null && \
      printf '\n%s\n%s\n%s\n' "$MARK" 'unset PYTHONPATH PYTHONHOME' 'hash -r' >> "$A"
      echo "  appended"
    fi
    tail -4 "$A"
  done

  echo "== verify: activate from polluted env =="
  docker exec -e PYTHONPATH=/usr/local/lib/python3.12/site-packages corex5-py311 \
    bash -c 'source /opt/corex311/bin/activate; echo "PYTHONPATH=${PYTHONPATH:-<unset>}"; python -c "import torch,vllm;print(\"base\",torch.__version__,vllm.__version__)"' 2>&1 | tail -3
  docker exec -e PYTHONPATH=/usr/local/lib/python3.12/site-packages corex5-py311 \
    bash -c 'source /opt/corex311-cpython-vllm/bin/activate; echo "PYTHONPATH=${PYTHONPATH:-<unset>}"; python -c "import torch,vllm;print(\"pgo\",torch.__version__,vllm.__version__)"' 2>&1 | tail -3

  echo "== verify: deactivate restores nothing harmful =="
  docker exec corex5-py311 bash -c 'source /opt/corex311/bin/activate; deactivate; echo "after deactivate PYTHONPATH=${PYTHONPATH:-<unset>}"' 2>&1 | tail -2

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
