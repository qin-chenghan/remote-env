#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。核实容器内 3.12 与 /opt/corex311 3.11 的两套 vLLM，以及 mock/插桩各自作用在哪套。
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

  echo "== 1. 两个解释器 =="
  docker exec vllm bash -lc '
    echo "default python3: $(command -v python3) $(python3 -V 2>&1)"
    echo "venv python:      /opt/corex311/bin/python3 $(/opt/corex311/bin/python3 -V 2>&1)"
    echo "PATH=$PATH"
  ' 2>&1 | head -6

  echo "== 2. 两套 site-packages 里的 vllm/torch =="
  docker exec vllm bash -lc '
    echo "-- 3.12 (/usr/local/lib/python3.12/site-packages)"
    ls -d /usr/local/lib/python3.12/site-packages/vllm* /usr/local/lib/python3.12/site-packages/torch* 2>/dev/null | head -6
    echo "-- 3.11 (/opt/corex311/lib/python3.11/site-packages)"
    ls -d /opt/corex311/lib/python3.11/site-packages/vllm* /opt/corex311/lib/python3.11/site-packages/torch* 2>/dev/null | head -6
  ' 2>&1 | head -16

  echo "== 3. 插桩在哪套里 =="
  docker exec vllm bash -lc '
    grep -c "kperf_start_type" /usr/local/lib/python3.12/site-packages/vllm/v1/executor/multiproc_executor.py 2>/dev/null || echo "3.12: 无该文件或无匹配"
    grep -n "kperf_start_type" /opt/corex311/lib/python3.11/site-packages/vllm/v1/executor/multiproc_executor.py 2>/dev/null | head -3
  ' 2>&1 | head -6

  echo "== 4. 两套 vllm 的版本与 worker 文件 =="
  docker exec vllm bash -lc '
    grep -m1 -E "^Version|__version__" /usr/local/lib/python3.12/site-packages/vllm/version.py 2>/dev/null
    grep -m1 -E "^Version|__version__" /opt/corex311/lib/python3.11/site-packages/vllm/version.py 2>/dev/null
    ls /usr/local/lib/python3.12/site-packages/vllm/v1/worker/gpu_worker.py 2>/dev/null
    ls /opt/corex311/lib/python3.11/site-packages/vllm/v1/worker/gpu_worker.py 2>/dev/null
  ' 2>&1 | head -8

  echo "== 5. mock 在 3.12 下能否激活 =="
  docker exec vllm bash -lc '
    PYTHONPATH=/home/qch/mock_vllm python3 -c "import mock_gpu.autoload" 2>&1 | tail -4
  ' 2>&1 | head -6

  echo "== 6. mock 在 3.11 下能否激活（对照）=="
  docker exec vllm bash -lc '
    PYTHONPATH=/home/qch/mock_vllm /opt/corex311/bin/python3 -c "import mock_gpu.autoload" 2>&1 | tail -3
  ' 2>&1 | head -5

  echo "== 7. harness 用的解释器 =="
  grep -n "PYTHON_BIN\|PREFIX=" /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base_mock.sh 2>/dev/null | head -4
  docker exec vllm bash -lc 'grep -n "PYTHON_BIN\|PREFIX=" /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base_mock.sh 2>/dev/null | head -4' 2>&1 | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
