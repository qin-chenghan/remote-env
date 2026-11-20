#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。定位 kperf_start_type 的来源与缺失原因。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
VLLM=/opt/corex311/lib/python3.11/site-packages/vllm

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. worker_busy_loop 附近的插桩代码 =="
  docker exec "$C" bash -lc "sed -n '955,1000p' $VLLM/v1/executor/multiproc_executor.py" 2>&1

  echo "== 2. 全 site-packages 里 kperf_start_type 的定义/引用 =="
  docker exec "$C" bash -lc "grep -rn 'kperf_start_type' /opt/corex311/lib/python3.11/site-packages/ 2>/dev/null | head -8" 2>&1

  echo "== 3. 文件头部有没有 import =="
  docker exec "$C" bash -lc "sed -n '1,60p' $VLLM/v1/executor/multiproc_executor.py | grep -nE 'import|kperf'" 2>&1 | head -20

  echo "== 4. kperf 模块 / 库是否存在 =="
  docker exec "$C" bash -lc '
    /opt/corex311/bin/python3 -c "import kperf; print(\"kperf ok\", kperf.__file__)" 2>&1 | tail -2
    ldconfig -p 2>/dev/null | grep -i kperf | head -3
    ls /usr/local/lib/libkperf* /usr/lib/libkperf* 2>/dev/null | head -3
  ' 2>&1 | head -10

  echo "== 5. 相关环境变量 =="
  docker exec "$C" bash -lc 'env | grep -iE "kperf|hotspot|host_opt" | head -8; echo "(空则未设置)"' 2>&1

  echo "== 6. light_host_worker 是否有 kperf 依赖 =="
  docker exec "$C" bash -lc '
    f=$(/opt/corex311/bin/python3 -c "import light_host_worker; print(light_host_worker.__file__)" 2>/dev/null)
    echo "file=$f"; grep -n "kperf" "$f" 2>/dev/null | head -5 || echo "无 kperf 引用"
  ' 2>&1 | head -8

  echo "== 7. 与 mock 镜像对比：同一文件的 diff 摘要 =="
  docker exec corex5-py311-mock bash -lc \
    "sed -n '955,985p' $VLLM/v1/executor/multiproc_executor.py" 2>&1 | head -20

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
