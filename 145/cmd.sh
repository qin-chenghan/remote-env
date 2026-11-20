#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。用脚本文件（不用 stdin）分别经 bash -lc 跑两个解释器，取真实版本与 _ctypes 状态。
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

  echo "== 1. 两个 python3 的路径（bash -lc vs 裸 exec）=="
  docker exec vllm bash -lc 'command -v python3; python3 -V; ls -l /usr/bin/python3 /usr/local/bin/python3 2>/dev/null' 2>&1 | head -6

  echo "== 2. 写出探针脚本 =="
  docker exec vllm bash -lc 'cat > /tmp/probe_ver.py <<"PY"
import sys
print("interpreter:", sys.executable, sys.version.split()[0])
for name in ("torch", "vllm", "triton"):
    try:
        mod = __import__(name)
        print(f"{name:8s} {getattr(mod, \"__version__\", \"?\")}")
    except Exception as e:
        print(f"{name:8s} FAIL {type(e).__name__}: {str(e)[:80]}")
try:
    import ixformer
    print("ixformer", getattr(ixformer, "__version__", "?"))
except Exception as e:
    print("ixformer FAIL", type(e).__name__, str(e)[:60])
try:
    import ctypes
    print("ctypes   ok")
except Exception as e:
    print("ctypes   FAIL", type(e).__name__, str(e)[:80])
PY
ls -l /tmp/probe_ver.py'

  echo "== 3. 3.12（/usr/local/bin/python3，bash -lc）=="
  docker exec vllm bash -lc 'python3 /tmp/probe_ver.py' 2>&1 | tail -8

  echo "== 4. 3.11（/opt/corex311/bin/python3，bash -lc）=="
  docker exec vllm bash -lc '/opt/corex311/bin/python3 /tmp/probe_ver.py' 2>&1 | tail -8

  echo "== 5. 系统 /usr/bin/python3 是什么 =="
  docker exec vllm bash -lc '/usr/bin/python3 -V 2>&1; /usr/bin/python3 -c "import sys; print(sys.path[:3])" 2>&1 | tail -2' 2>&1 | head -4

  echo "== 6. 3.12 的 _ctypes 依赖（libpython）=="
  docker exec vllm bash -lc '
    ldd /usr/local/lib/python3.12/lib-dynload/_ctypes.cpython-312-aarch64-linux-gnu.so 2>/dev/null | head -6
    ls -l /usr/local/lib/libpython3.12* /usr/lib/libpython3.12* 2>/dev/null | head -4
  ' 2>&1 | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
