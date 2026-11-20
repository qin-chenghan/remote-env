#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：修补 kperf 调用——保留 `kperf_start_type(103)`，补一个“有则用、无则空”的导入回退。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
F=/opt/corex311/lib/python3.11/site-packages/vllm/v1/executor/multiproc_executor.py
BAK="$F.bak-kperf-$(date +%Y%m%d%H%M%S)"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 修改前 =="
  docker exec "$C" bash -lc "sha256sum $F; grep -n 'kperf_start_type' $F" 2>&1

  echo "== 2. 备份并插入导入回退（幂等）=="
  docker exec -i "$C" /opt/corex311/bin/python3 - "$F" "$BAK" <<'PY'
import pathlib, shutil, sys

path, bak = pathlib.Path(sys.argv[1]), sys.argv[2]
src = path.read_text()
if "from kperf import kperf_start_type" in src or "def kperf_start_type" in src:
    print("already patched")
    raise SystemExit
shutil.copy2(path, bak)
anchor = "from threading import Thread\n"
block = (
    "\ntry:  # kperf instrumentation hook is optional\n"
    "    from kperf import kperf_start_type  # noqa: F401\n"
    "except Exception:  # noqa: BLE001\n"
    "    def kperf_start_type(*args, **kwargs):\n"
    "        return None\n"
)
idx = src.index(anchor) + len(anchor)
path.write_text(src[:idx] + block + src[idx:])
print("patched, backup:", bak)
PY

  echo "== 3. 修改后上下文与语法 =="
  docker exec "$C" bash -lc "sed -n '17,30p' $F" 2>&1
  docker exec "$C" bash -lc "/opt/corex311/bin/python3 -m py_compile $F && echo 'py_compile OK'" 2>&1

  echo "== 4. 真实导入验证（登录 shell，带 corex 库）=="
  docker exec "$C" bash -lc '
    /opt/corex311/bin/python3 - <<PY
from vllm.v1.executor import multiproc_executor as m
print("callable:", callable(m.kperf_start_type))
m.kperf_start_type(103)
print("call ok")
PY' 2>&1 | tail -4

  echo "== 5. 结果与回滚 =="
  docker exec "$C" bash -lc "sha256sum $F; grep -n 'kperf_start_type' $F" 2>&1
  echo "回滚：docker exec $C cp -a $BAK $F"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
