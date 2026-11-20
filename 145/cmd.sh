#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。找 kperf 模块/库的真实位置与接口，为“保留调用并修补”做准备。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 容器内所有 python 环境是否装有 kperf =="
  docker exec "$C" bash -lc '
    for py in /opt/corex311/bin/python3 /opt/corex311-cpython-vllm/bin/python3 /usr/bin/python3 /usr/local/bin/python3; do
      [ -x "$py" ] || continue
      echo "-- $py"
      "$py" -c "import kperf, inspect; print(kperf.__file__); print([n for n in dir(kperf) if not n.startswith(\"_\")])" 2>&1 | tail -3
    done
  ' 2>&1 | head -20

  echo "== 2. 文件系统里搜 kperf 模块 / 共享库 =="
  docker exec "$C" bash -lc '
    ls -l /usr/local/lib/python3*/site-packages/kperf* /usr/lib/python3*/site-packages/kperf* \
          /opt/corex311/lib/python3.11/site-packages/kperf* 2>/dev/null | head -6
    ls -l /usr/local/lib/libkperf* /usr/lib64/libkperf* /usr/lib/libkperf* 2>/dev/null | head -4
    find /usr /opt -maxdepth 6 -name "kperf*" 2>/dev/null | head -8
  ' 2>&1 | head -14

  echo "== 3. 全盘搜 kperf_start_type 的定义（排除 vllm 那处调用）=="
  docker exec "$C" bash -lc '
    grep -rln "def kperf_start_type\|kperf_start_type *=" /usr /opt /home 2>/dev/null | head -5
  ' 2>&1 | head -6

  echo "== 4. 宿主上是否有 kperf（可能挂在宿主而非容器）=="
  ls -l /usr/local/lib/libkperf* /usr/lib64/libkperf* 2>/dev/null | head -4
  find /usr/local /opt -maxdepth 4 -name "kperf*" 2>/dev/null | head -6
  command -v kperf || true

  echo "== 5. 镜像内其他 kperf 痕迹（字符串）=="
  docker exec "$C" bash -lc '
    grep -rln "kperf_start_type\|kperf_stop" /opt/corex311/lib/python3.11/site-packages/vllm 2>/dev/null | head -5
    grep -rn "kperf_start_type" /opt/corex311/lib/python3.11/site-packages/vllm 2>/dev/null | head -8
  ' 2>&1 | head -12

  echo "== 6. light_host_worker 位置（该 run 用的 worker-cls）=="
  docker exec "$C" bash -lc '
    find /home -maxdepth 3 -name "light_host_worker.py" 2>/dev/null | head -3
  ' 2>&1 | head -4

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
