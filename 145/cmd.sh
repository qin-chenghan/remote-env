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
  # 在 /home/qch/clamp_opt 下新建工作目录（不碰仓库），构建基线 .so 并计时。

  docker exec fusionv1 bash -lc '
set -uo pipefail
D=/home/qch/clamp_opt
SRC=/home/qch/projects/vllm/workplace/lib_preprocess.cpp

echo "== 1. 准备目录（全部为新建）=="
mkdir -p "$D"
ls -la "$D" 2>&1 | head -5

echo "== 2. 构建基线 .so =="
g++ -std=c++14 -march=armv8.2-a+fp16+dotprod -fopenmp -O3 \
    -shared -fPIC -o "$D/libpreprocess_base.so" "$SRC" 2>&1 | tail -15
echo "build rc=$?"
ls -l "$D/libpreprocess_base.so" 2>&1

echo "== 3. 写 ctypes 计时脚本（仅标准库）=="
cat > "$D/clamp_neon_opt_bench.py" <<"PY"
import ctypes, sys, time

OUT_H = OUT_W = 224
OUT_N = 6 * OUT_H * OUT_W

def load(path):
    lib = ctypes.CDLL(path)
    fn = lib.combined_preprocess
    fn.argtypes = [ctypes.POINTER(ctypes.c_uint8),
                   ctypes.POINTER(ctypes.c_float),
                   ctypes.c_int, ctypes.c_int, ctypes.c_int]
    fn.restype = None
    return fn

def make_input(h, w):
    n = h * w * 3
    buf = (ctypes.c_uint8 * n)()
    for i in range(n):
        buf[i] = (i * 7 + 13) % 256
    return buf

def bench(fn, h, w, threads, iters):
    src = make_input(h, w)
    out = (ctypes.c_float * OUT_N)()
    for _ in range(3):
        fn(src, out, h, w, threads)
    t0 = time.perf_counter()
    for _ in range(iters):
        fn(src, out, h, w, threads)
    ms = (time.perf_counter() - t0) / iters * 1000
    return ms, out

fn = load(sys.argv[1])
print("lib:", sys.argv[1])
for (h, w, iters) in ((224, 224, 200), (481, 321, 100), (1080, 1920, 30)):
    for t in (1, 4):
        ms, out = bench(fn, h, w, t, iters)
        print("%dx%d threads=%d: %.3f ms" % (w, h, t, ms))
PY

echo "== 4. 基线计时 =="
cd "$D" || exit 1
taskset -c 0 python3 clamp_neon_opt_bench.py ./libpreprocess_base.so 2>&1 | tail -12
' 2>&1 | head -40

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
