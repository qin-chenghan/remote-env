#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 注意：本脚本在宿主机执行；/opt 属于容器，必须走 docker exec。
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
  echo "== inspect activate PYTHONPATH handling =="
  docker exec corex5-py311 bash -c 'for A in /opt/corex311/bin/activate /opt/corex311-cpython-vllm/bin/activate; do
    echo "-- $A"
    grep -n "PYTHONPATH" "$A" | head -12
    echo "   size=$(stat -c %s "$A")  sha=$(sha256sum "$A" | cut -c1-12)"
  done' 2>&1

  echo "== patch inside container =="
  docker exec -i corex5-py311 bash -s "$TS" <<'SH' 2>&1
set -x
TS=$1
MARK='# 184: strip container-level PYTHONPATH pollution'
for V in /opt/corex311 /opt/corex311-cpython-vllm; do
  A="$V/bin/activate"
  echo "-- $A"
  if grep -q "$MARK" "$A" 2>/dev/null; then
    echo "  already patched"
  else
    cp -a "$A" "$A.bak-pyenv-$TS" || exit 1
    printf '\n%s\n%s\n%s\n' "$MARK" 'unset PYTHONPATH PYTHONHOME' 'hash -r' >> "$A"
    echo "  appended"
  fi
  tail -5 "$A"
done
SH

  echo "== verify from polluted env =="
  for V in /opt/corex311 /opt/corex311-cpython-vllm; do
    echo "-- $V"
    docker exec -e PYTHONPATH=/usr/local/lib/python3.12/site-packages corex5-py311 \
      bash -c "source $V/bin/activate
        echo -n 'PYTHONPATH='; echo \"\${PYTHONPATH:-<unset>}\"
        python -c 'import sys, torch, vllm; print(\"torch\", torch.__version__, torch.__file__); print(\"vllm\", vllm.__version__)'" 2>&1 | tail -5
  done

  echo "== deactivate check =="
  docker exec corex5-py311 bash -c 'source /opt/corex311/bin/activate; deactivate; echo "after=${PYTHONPATH:-<unset>}"' 2>&1 | tail -2

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
