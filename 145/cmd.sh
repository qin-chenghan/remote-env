#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。取两个解释器的真实版本/依赖（脚本文件方式，避免转义问题）。
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

  echo "== 1. 写探针脚本（纯 ASCII、无转义）=="
  docker exec vllm bash -lc 'cat > /tmp/probe_ver.py <<PY
import sys
print("interpreter", sys.executable, sys.version.split()[0])
for name in ("torch", "vllm", "triton", "ixformer", "aiohttp", "numpy"):
    try:
        mod = __import__(name)
        ver = getattr(mod, "__version__", "?")
        print(name, ver)
    except Exception as e:
        print(name, "FAIL", type(e).__name__)
try:
    import ctypes
    print("ctypes ok")
except Exception as e:
    print("ctypes FAIL", type(e).__name__)
PY
wc -l /tmp/probe_ver.py'

  echo "== 2. 3.12 版本 =="
  docker exec vllm bash -lc 'python3 /tmp/probe_ver.py' 2>&1 | tail -9

  echo "== 3. 3.11 版本（对照）=="
  docker exec vllm bash -lc '/opt/corex311/bin/python3 /tmp/probe_ver.py' 2>&1 | tail -9

  echo "== 4. 裸 exec 解析到哪个 python3 =="
  docker exec vllm bash -c 'command -v python3; python3 -V' 2>&1 | head -4
  docker exec vllm /usr/bin/env python3 -V 2>&1 | head -2

  echo "== 5. 两套 multiproc_executor 的差异（只列 diff 行数）=="
  docker exec vllm bash -lc '
    diff /usr/local/lib/python3.12/site-packages/vllm/v1/executor/multiproc_executor.py \
         /opt/corex311/lib/python3.11/site-packages/vllm/v1/executor/multiproc_executor.py \
      | grep -cE "^[<>]" || true
    diff /usr/local/lib/python3.12/site-packages/vllm/v1/executor/multiproc_executor.py \
         /opt/corex311/lib/python3.11/site-packages/vllm/v1/executor/multiproc_executor.py \
      | grep -E "^[<>].*(kperf|ctypes)" || echo "只有 kperf 相关行"
  ' 2>&1 | head -6

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
