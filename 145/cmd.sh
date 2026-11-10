#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
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
  # 直接测量 v1/v2 各阶段耗时（两库各自导出 probe_stages / probe_stages_v2）。

  D=/home/qch/clamp_opt

  echo "== 1. 生成对比脚本（新文件）=="
  cat > "$D/clamp_neon_opt_stage_ab.py" <<'PY'
# [agent-opt] 生成文件，可安全删除。
import ctypes, sys

OUT_N = 6 * 224 * 224
PROTO = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(ctypes.c_float),
         ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_double)]

def load(path, name):
    lib = ctypes.CDLL(path)
    fn = getattr(lib, name)
    fn.argtypes = PROTO
    fn.restype = None
    return fn

def make_input(h, w):
    n = h * w * 3
    b = (ctypes.c_uint8 * n)()
    for i in range(n):
        b[i] = (i * 7 + 13) % 256
    return b

v1 = load(sys.argv[1], "probe_stages")
v2 = load(sys.argv[2], "probe_stages_v2")
out = (ctypes.c_float * OUT_N)()
ms = (ctypes.c_double * 4)()

STAGES = ("lut", "horizontal", "vertical", "normalize")

for (h, w, iters) in ((224, 224, 200), (481, 321, 100), (1080, 1920, 30)):
    src = make_input(h, w)
    acc = {1: [0.0] * 4, 2: [0.0] * 4}
    rounds = 3
    for _ in range(rounds):
        for tag, fn in ((1, v1), (2, v2)):
            for _ in range(2):
                fn(src, out, h, w, 1, ms)
            s = [0.0] * 4
            for _ in range(iters):
                fn(src, out, h, w, 1, ms)
                for k in range(4):
                    s[k] += ms[k]
            for k in range(4):
                acc[tag][k] += s[k] / iters
    a1 = [v / rounds for v in acc[1]]
    a2 = [v / rounds for v in acc[2]]
    print("\n=== %dx%d (1 thread) ===" % (w, h))
    print("%-12s %10s %10s %8s" % ("stage", "v1_ms", "v2_ms", "speedup"))
    for k, name in enumerate(STAGES):
        sp = a1[k] / a2[k] if a2[k] else 0.0
        print("%-12s %10.3f %10.3f %7.2fx" % (name, a1[k], a2[k], sp))
    print("%-12s %10.3f %10.3f %7.2fx" % ("TOTAL", sum(a1), sum(a2),
                                          sum(a1) / sum(a2) if sum(a2) else 0.0))
PY
  ls -l "$D/clamp_neon_opt_stage_ab.py"

  echo "== 2. 直接测各阶段（绑 cpu0）=="
  cd "$D" && taskset -c 0 python3 clamp_neon_opt_stage_ab.py ./libpreprocess_probe.so ./libpreprocess_v2.so 2>&1 | tail -30

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
