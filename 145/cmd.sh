#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：清理遗留 server（19:56 那次 lite 留下的 8948 进程），验证端口空闲，并检查 vllm 容器环境。
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

  echo "== 1. 确认遗留进程确实占着 8948 =="
  PIDS=$(pgrep -f "vllm.entrypoints.openai.api_server" 2>/dev/null)
  echo "pids: $PIDS"
  for p in $PIDS; do
    echo "-- pid $p 启动时间: $(ps -o lstart= -p "$p" 2>/dev/null)"
    echo "   cgroup: $(grep -m1 docker /proc/$p/cgroup 2>/dev/null | cut -d/ -f2)"
    echo "   监听(该进程 netns 视角):"
    awk '$4=="0A"{print "   addr=127.0.0.1 port="strtonum("0x"substr($2,index($2,":")+1))}' \
      /proc/$p/net/tcp 2>/dev/null | grep -E "port=(8848|8948)" || echo "   (该 netns 无 8848/8948 监听)"
  done

  echo "== 2. 停止遗留 server（只停 mock 容器里 8948 那个）=="
  docker exec "$CONTAINER" bash -lc 'pkill -f "vllm.entrypoints.openai.api_server --host 127.0.0.1 --port 8948"' 2>/dev/null
  sleep 3
  pgrep -af "vllm.entrypoints.openai.api_server" | grep -v grep || echo "已无 api_server 进程"

  echo "== 3. 端口验证（宿主 netns 直接 bind）=="
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

  echo "== 4. 容器内同样验证 =="
  for c in vllm corex5-py311-mock; do
    echo "-- $c"
    docker exec "$c" /opt/corex311/bin/python3 - <<'PY' 2>&1 | tail -3
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

  echo "== 5. vllm 容器环境核对 =="
  docker exec vllm bash -lc '
    echo "mock 代码: $(ls /home/qch/mock_vllm/mock_gpu 2>/dev/null | head -3 | tr "\n" " ")"
    echo "宿主导入? $(mount 2>/dev/null | grep -c /home)"
    ls -ld /home/huawei_ts_program/litehost_perf_opt
    ls /home/huawei_ts_program/litehost_perf_opt | head -8
    echo "模型: $(du -sh /home/model/* 2>/dev/null | head -2)"
  ' 2>&1 | head -14

  echo "== 6. 残留 shm / socket =="
  docker exec vllm bash -lc 'ls -l /dev/shm 2>/dev/null | head -6' 2>&1 | head -8
  ls -l /tmp/*.sock 2>/dev/null | head -5 || echo "无 /tmp socket"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
