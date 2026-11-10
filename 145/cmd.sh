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
  # 新建探针文件（#include 原实现，不改原文件），测量各阶段耗时。

  D=/home/qch/clamp_opt
  R=/home/qch/projects/vllm/workplace

  echo "== 1. 生成探针源码（新文件）=="
  cat > "$D/clamp_neon_opt_probe.cpp" <<'CPP'
// [agent-opt] 生成文件，可安全删除。仅用于分阶段计时，不改原实现。
#include "/home/qch/projects/vllm/workplace/lib_preprocess.cpp"
#include <chrono>

static inline double now_ms() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

// out_ms[0]=lut+alloc, [1]=horizontal, [2]=vertical, [3]=normalize
extern "C" void probe_stages(const uint8_t* input, float* output,
                             int H_in, int W_in, int num_threads, double* out_ms)
{
    double t0 = now_ms();
    Lut xlut = build_lut(kOutputSize, W_in);
    Lut ylut = build_lut(kOutputSize, H_in);
    const int stride = kOutputSize * kInputChannels;
    float* mid = static_cast<float*>(
        checked_alloc(static_cast<size_t>(H_in) * static_cast<size_t>(stride),
                      sizeof(float), "mid"));
    double t1 = now_ms();

    ResizePassParams hp{H_in, kOutputSize, num_threads, &xlut};
    resize_horizontal(input, mid, W_in, hp);
    double t2 = now_ms();

    constexpr size_t kResizedBytes = static_cast<size_t>(kOutputPlane) * kInputChannels;
    uint8_t* resized = static_cast<uint8_t*>(checked_alloc(kResizedBytes, 1, "resized"));
    ResizePassParams vp{kOutputSize, kOutputSize, num_threads, &ylut};
    resize_vertical(mid, resized, vp);
    double t3 = now_ms();

    neon_normalize(resized, output, num_threads);
    double t4 = now_ms();

    out_ms[0] = t1 - t0;
    out_ms[1] = t2 - t1;
    out_ms[2] = t3 - t2;
    out_ms[3] = t4 - t3;

    std::free(resized);
    std::free(mid);
    free_lut(xlut);
    free_lut(ylut);
}
CPP
  ls -l "$D/clamp_neon_opt_probe.cpp"

  echo "== 2. 编译探针 .so =="
  g++ -std=c++14 -march=armv8.2-a+fp16+dotprod -fopenmp -O3 \
      -shared -fPIC -o "$D/libpreprocess_probe.so" "$D/clamp_neon_opt_probe.cpp" 2>&1 | tail -10
  echo "build rc=$?"
  ls -l "$D/libpreprocess_probe.so"

  echo "== 3. 生成计时脚本（新文件）=="
  cat > "$D/clamp_neon_opt_stages.py" <<'PY'
# [agent-opt] 生成文件，可安全删除。
import ctypes, sys, time

OUT_H = OUT_W = 224
OUT_N = 6 * OUT_H * OUT_W

lib = ctypes.CDLL(sys.argv[1])
fn = lib.probe_stages
fn.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(ctypes.c_float),
               ctypes.c_int, ctypes.c_int, ctypes.c_int,
               ctypes.POINTER(ctypes.c_double)]
fn.restype = None

def make_input(h, w):
    n = h * w * 3
    b = (ctypes.c_uint8 * n)()
    for i in range(n):
        b[i] = (i * 7 + 13) % 256
    return b

out = (ctypes.c_float * OUT_N)()
ms = (ctypes.c_double * 4)()

print("%-14s %-4s %8s %8s %8s %8s %8s" %
      ("size", "thr", "lut", "horizontal", "vertical", "normalize", "total"))
for (h, w, iters) in ((224, 224, 100), (481, 321, 100), (1080, 1920, 30)):
    src = make_input(h, w)
    for _ in range(3):
        fn(src, out, h, w, 1, ms)
    acc = [0.0] * 4
    for _ in range(iters):
        fn(src, out, h, w, 1, ms)
        for k in range(4):
            acc[k] += ms[k]
    vals = [a / iters for a in acc]
    print("%-14s %-4d %8.3f %8.3f %8.3f %8.3f %8.3f" %
          ("%dx%d" % (w, h), 1, vals[0], vals[1], vals[2], vals[3], sum(vals)))
PY
  ls -l "$D/clamp_neon_opt_stages.py"

  echo "== 4. 跑分阶段计时（绑 cpu0）=="
  cd "$D" && taskset -c 0 python3 clamp_neon_opt_stages.py ./libpreprocess_probe.so 2>&1 | tail -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
