#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读评估——能否把 mock / 插桩 / harness 切到容器自带的 3.12。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

S312=/usr/local/lib/python3.12/site-packages
S311=/opt/corex311/lib/python3.11/site-packages
LK=/home/l00946765/workspace/performance-tools/libkperf

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 解释器 =="
  docker exec vllm bash -lc 'command -v python3; python3 -V; /opt/corex311/bin/python3 -V' 2>&1

  echo "== 2. 3.12 侧关键包版本（vllm/torch/triton/ixformer）=="
  docker exec vllm python3 - <<'PY' 2>&1 | tail -12
import importlib.metadata as md
for name in ("vllm", "torch", "triton", "ixformer", "transformers", "pillow", "numpy"):
    try:
        print(f"{name:14s} {md.version(name)}")
    except Exception as e:
        print(f"{name:14s} MISSING ({type(e).__name__})")
PY

  echo "== 3. 3.11 侧同项（对照）=="
  docker exec vllm /opt/corex311/bin/python3 - <<'PY' 2>&1 | tail -12
import importlib.metadata as md
for name in ("vllm", "torch", "triton", "ixformer", "transformers", "pillow", "numpy"):
    try:
        print(f"{name:14s} {md.version(name)}")
    except Exception as e:
        print(f"{name:14s} MISSING ({type(e).__name__})")
PY

  echo "== 4. 3.12 套里 mock 依赖的文件是否存在 =="
  docker exec vllm bash -lc "
    for f in vllm/v1/worker/gpu_worker.py vllm/v1/worker/gpu_model_runner.py \
               vllm/v1/executor/multiproc_executor.py vllm/v1/worker/block_table.py \
               vllm/utils/torch_utils.py vllm/compilation/cuda_graph.py; do
      printf '%-46s ' \$f; [ -f $S312/\$f ] && echo present || echo MISSING
    done
  " 2>&1

  echo "== 5. 插桩在 3.12 套里的现状 =="
  docker exec vllm bash -lc "grep -c kperf_start_type $S312/vllm/v1/executor/multiproc_executor.py 2>/dev/null || echo 0" 2>&1

  echo "== 6. libkperf.py 是纯 python 还是扩展 =="
  grep -n "ctypes\|CDLL\|import " "$LK/libkperf.py" 2>/dev/null | head -12
  ls -l "$LK"/*.so 2>/dev/null | head -4
  file "$LK"/*.so 2>/dev/null | cut -c1-110 | head -3

  echo "== 7. harness 与 worker 脚本对解释器的依赖 =="
  docker exec vllm bash -lc '
    grep -n "PYTHON_BIN\|PREFIX=" /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base_mock.sh | head -3
    head -12 /home/huawei_ts_program/litehost_perf_opt/light_host_worker.py 2>/dev/null
    /opt/corex311/bin/python3 -m pip list 2>/dev/null | grep -iE "aiohttp|requests|numpy|pillow" | head -6
  ' 2>&1 | head -22

  echo "== 8. mock 在 3.12 下能否 activate（只 import，不起服务）=="
  docker exec vllm bash -lc 'PYTHONPATH=/home/qch/mock_vllm python3 -c "import mock_gpu.autoload" 2>&1 | tail -5' 2>&1 | head -7

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
