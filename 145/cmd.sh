#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。补齐版本对比（上次 docker exec 漏了 -i），并看测试人员的 kperf 接法。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

LK=/home/l00946765/workspace/performance-tools/libkperf
F311=/opt/corex311/lib/python3.11/site-packages/vllm/v1/executor/multiproc_executor.py

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 3.12 关键包版本 =="
  docker exec -i vllm python3 - <<'PY' 2>&1 | tail -10
import importlib.metadata as md
for n in ("vllm", "torch", "triton", "ixformer", "transformers", "numpy"):
    try:
        print(f"{n:13s} {md.version(n)}")
    except Exception as e:
        print(f"{n:13s} MISSING")
PY

  echo "== 2. 3.11 关键包版本（对照）=="
  docker exec -i vllm /opt/corex311/bin/python3 - <<'PY' 2>&1 | tail -10
import importlib.metadata as md
for n in ("vllm", "torch", "triton", "ixformer", "transformers", "numpy"):
    try:
        print(f"{n:13s} {md.version(n)}")
    except Exception as e:
        print(f"{n:13s} MISSING")
PY

  echo "== 3. libkperf.py 里 kperf_start_type 的定义 =="
  grep -n "def kperf_start_type\|kperf_start_type" "$LK/libkperf.py" 2>/dev/null | head -6
  grep -rn "def kperf_start_type" "$LK" 2>/dev/null | head -4

  echo "== 4. 测试人员在 3.11 里最终怎么接的 =="
  docker exec vllm bash -lc "grep -n 'kperf' $F311" 2>&1 | head -6
  docker exec vllm bash -lc "sed -n '1,40p' $F311 | grep -nE 'import|kperf'" 2>&1 | head -10
  docker exec vllm bash -lc "sed -n '972,988p' $F311" 2>&1

  echo "== 5. 3.11 套里 kperf 模块从哪来 =="
  docker exec vllm bash -lc '
    /opt/corex311/bin/python3 -c "import kperf; print(kperf.__file__)" 2>&1 | tail -2
    ls -d /opt/corex311/lib/python3.11/site-packages/kperf* /opt/corex311/lib/python3.11/site-packages/libkperf* 2>/dev/null
    /opt/corex311/bin/python3 -m pip list 2>/dev/null | grep -i kperf | head -3
  ' 2>&1 | head -8

  echo "== 6. 3.12 下 mock 激活后再 import vLLM 关键类（补丁是否真的落地）=="
  docker exec -i vllm bash -lc '
    PYTHONPATH=/home/qch/mock_vllm python3 - <<PY 2>&1 | tail -6
import mock_gpu.autoload
from vllm.v1.worker.gpu_model_runner import GPUModelRunner
import vllm.v1.worker.gpu_worker as gw
print("Worker patched:", gw.Worker.init_device.__module__, gw.Worker.init_device.__qualname__)
print("vllm import ok")
PY
  '

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
