#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。读 3.12/3.11 的真实模块版本，并检查 libkperf.so 与插桩可行性。
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

  echo "== 1. 3.12 模块版本（从模块属性读）=="
  docker exec -i vllm python3 - <<'PY' 2>&1 | tail -8
import torch, vllm, triton
print("torch     ", getattr(torch, "__version__", "?"))
print("vllm      ", getattr(vllm, "__version__", "?"))
print("triton    ", getattr(triton, "__version__", "?"))
try:
    import ixformer; print("ixformer  ", getattr(ixformer, "__version__", "?"))
except Exception as e:
    print("ixformer  ", type(e).__name__)
PY

  echo "== 2. 3.11 模块版本（对照）=="
  docker exec -i vllm /opt/corex311/bin/python3 - <<'PY' 2>&1 | tail -8
import torch, vllm, triton
print("torch     ", getattr(torch, "__version__", "?"))
print("vllm      ", getattr(vllm, "__version__", "?"))
print("triton    ", getattr(triton, "__version__", "?"))
try:
    import ixformer; print("ixformer  ", getattr(ixformer, "__version__", "?"))
except Exception as e:
    print("ixformer  ", type(e).__name__)
PY

  echo "== 3. 3.12 的 vllm 是否与 3.11 同一份源码（比 sha256）=="
  docker exec vllm bash -lc '
    for f in vllm/v1/executor/multiproc_executor.py vllm/v1/worker/gpu_worker.py; do
      printf "%-45s " "$f"
      sha256sum /usr/local/lib/python3.12/site-packages/$f /opt/corex311/lib/python3.11/site-packages/$f 2>/dev/null | awk "{print \$1}" | uniq | wc -l | tr -d "\n"
      echo " (1=相同 2=不同)"
    done
  ' 2>&1

  echo "== 4. libkperf.so 是否存在、架构、导出符号 =="
  docker exec vllm bash -lc '
    ls -l /home2/libkperf/libkperf.so 2>&1
    file /home2/libkperf/libkperf.so 2>&1 | cut -c1-110
    nm -D --defined-only /home2/libkperf/libkperf.so 2>/dev/null | grep -i kperf_start_type | head -3
  ' 2>&1 | head -8

  echo "== 5. ctypes 加载测试（3.12 解释器）=="
  docker exec -i vllm python3 - <<'PY' 2>&1 | tail -4
import ctypes
try:
    lib = ctypes.CDLL("/home2/libkperf/libkperf.so")
    print("CDLL ok; symbol:", hasattr(lib, "kperf_start_type"))
except Exception as e:
    print("CDLL failed:", type(e).__name__, e)
PY

  echo "== 6. 3.12 的 multiproc_executor 是否已有 ctypes import =="
  docker exec vllm bash -lc "grep -n 'import ctypes\|libkperf' /usr/local/lib/python3.12/site-packages/vllm/v1/executor/multiproc_executor.py | head -4" 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
