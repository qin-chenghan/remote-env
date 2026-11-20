#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：SIGKILL 遗留进程（它已不再监听但 TERM 无效），再双向验证端口。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

CONTAINER=corex5-py311-mock

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 遗留进程状态 =="
  pgrep -af "vllm.entrypoints.openai.api_server" | grep -v grep || echo "无进程"
  for p in $(pgrep -f "vllm.entrypoints.openai.api_server" 2>/dev/null); do
    ps -o pid,stat,etime,wchan= -p "$p" 2>/dev/null
  done

  echo "== 2. SIGKILL 遗留进程 =="
  docker exec "$CONTAINER" bash -lc \
    'pkill -9 -f "vllm.entrypoints.openai.api_server --host 127.0.0.1 --port 8948"' 2>/dev/null
  sleep 3
  if pgrep -f "vllm.entrypoints.openai.api_server" >/dev/null 2>&1; then
    echo "!! SIGKILL 后仍有进程，考虑 docker restart $CONTAINER"
    ps -o pid,stat,args -p $(pgrep -f "vllm.entrypoints.openai.api_server" | head -3) 2>/dev/null
  else
    echo "已无 api_server 进程"
  fi

  echo "== 3. 端口验证（宿主）=="
  python3.11 - <<'PY'
import socket
for port in (8948, 8848):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port)); print(f"port {port}: FREE")
    except OSError as e:
        print(f"port {port}: IN USE ({e})")
    finally:
        s.close()
PY

  echo "== 4. 端口验证（两个容器内，-i 传 stdin）=="
  for c in vllm "$CONTAINER"; do
    echo "-- $c"
    docker exec -i "$c" /opt/corex311/bin/python3 - <<'PY' 2>&1 | tail -3
import socket
for port in (8948, 8848):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port)); print(f"  port {port}: FREE")
    except OSError as e:
        print(f"  port {port}: IN USE ({e})")
    finally:
        s.close()
PY
  done

  echo "== 5. 确认 mock 容器仍正常 =="
  docker ps --filter "name=$CONTAINER" --format '{{.Names}} {{.Status}}'
  docker exec "$CONTAINER" bash -lc \
    'PYTHONPATH=/home/qch/mock_vllm /opt/corex311/bin/python3 -c "import mock_gpu.autoload"' 2>&1 | tail -2

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
