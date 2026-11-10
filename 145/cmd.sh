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
  # 新建 clamp 成本剥离实验（只改 clamp 语义，其余与原版完全相同）。

  D=/home/qch/clamp_opt

  echo "== 1. 生成实验源码（新文件）=="
  cat > "$D/clamp_neon_opt_clampcost.cpp" <<'CPP'
// [agent-opt] 生成文件，可安全删除。仅用于剥离 clamp 各组成部分的成本。
#include "/home/qch/projects/vllm/workplace/lib_preprocess.cpp"
#include <chrono>

static inline double cc_now_ms() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

// 0: 原版(round+钳位)  1: 裸转换  2: 仅 round  3: 仅钳位
template <int MODE>
static inline uint8_t clamp_variant(float v) {
    if (MODE == 0) return clamp_to_u8(v);
    if (MODE == 1) return static_cast<uint8_t>(static_cast<int32_t>(v));
    if (MODE == 2) return static_cast<uint8_t>(static_cast<int32_t>(std::round(v)));
    return static_cast<uint8_t>(
        static_cast<int32_t>(std::max(0.0f, std::min(kUint8ToFloatDivisor, v))));
}

template <int MODE>
static void resize_vertical_mode(const float* mid, uint8_t* output,
                                 const ResizePassParams& p)
{
    const int stride = p.W_out * kInputChannels;
#pragma omp parallel for schedule(static) num_threads(p.num_threads)
    for (int y = 0; y < p.H; ++y) {
        uint8_t* dst = output + y * p.W_out * kInputChannels;
        int n = p.lut->count[y];
        int ymin = p.lut->start[y];
        const float* w_row = p.lut->w + y * p.lut->ksize;
        for (int x = 0; x < p.W_out; ++x) {
            float R = 0.0f, G = 0.0f, B = 0.0f;
            for (int k = 0; k < n; ++k) {
                const float* src_row = mid + (ymin + k) * stride + x * kInputChannels;
                float wk = w_row[k];
                R += src_row[kChannelR] * wk;
                G += src_row[kChannelG] * wk;
                B += src_row[kChannelB] * wk;
            }
            int off = x * kInputChannels;
            dst[off + kChannelR] = clamp_variant<MODE>(R);
            dst[off + kChannelG] = clamp_variant<MODE>(G);
            dst[off + kChannelB] = clamp_variant<MODE>(B);
        }
    }
}

extern "C" void probe_mode(int mode, const uint8_t* input, float* output,
                           int H_in, int W_in, int num_threads, double* out_ms)
{
    double t0 = cc_now_ms();
    Lut xlut = build_lut(kOutputSize, W_in);
    Lut ylut = build_lut(kOutputSize, H_in);
    const int stride = kOutputSize * kInputChannels;
    float* mid = static_cast<float*>(
        checked_alloc(static_cast<size_t>(H_in) * static_cast<size_t>(stride),
                      sizeof(float), "mid"));
    double t1 = cc_now_ms();

    ResizePassParams hp{H_in, kOutputSize, num_threads, &xlut};
    resize_horizontal(input, mid, W_in, hp);
    double t2 = cc_now_ms();

    constexpr size_t kResizedBytes = static_cast<size_t>(kOutputPlane) * kInputChannels;
    uint8_t* resized = static_cast<uint8_t*>(checked_alloc(kResizedBytes, 1, "resized"));
    ResizePassParams vp{kOutputSize, kOutputSize, num_threads, &ylut};
    switch (mode) {
        case 0: resize_vertical_mode<0>(mid, resized, vp); break;
        case 1: resize_vertical_mode<1>(mid, resized, vp); break;
        case 2: resize_vertical_mode<2>(mid, resized, vp); break;
        default: resize_vertical_mode<3>(mid, resized, vp); break;
    }
    double t3 = cc_now_ms();

    neon_normalize(resized, output, num_threads);
    double t4 = cc_now_ms();

    out_ms[0] = t1 - t0; out_ms[1] = t2 - t1; out_ms[2] = t3 - t2; out_ms[3] = t4 - t3;
    std::free(resized);
    std::free(mid);
    free_lut(xlut);
    free_lut(ylut);
}
CPP
  ls -l "$D/clamp_neon_opt_clampcost.cpp"

  echo "== 2. 编译 =="
  g++ -std=c++14 -march=armv8.2-a+fp16+dotprod -fopenmp -O3 \
      -shared -fPIC -o "$D/libpreprocess_clampcost.so" "$D/clamp_neon_opt_clampcost.cpp" 2>&1 | tail -12
  echo "build rc=$?"
  ls -l "$D/libpreprocess_clampcost.so"

  echo "== 3. 生成测量脚本（新文件）=="
  cat > "$D/clamp_neon_opt_clampcost.py" <<'PY'
# [agent-opt] 生成文件，可安全删除。
import ctypes, sys, time

OUT_N = 6 * 224 * 224
MODES = {0: "full(round+clamp)", 1: "cast only", 2: "round only", 3: "clamp only"}

lib = ctypes.CDLL(sys.argv[1])
fn = lib.probe_mode
fn.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint8),
               ctypes.POINTER(ctypes.c_float), ctypes.c_int, ctypes.c_int,
               ctypes.c_int, ctypes.POINTER(ctypes.c_double)]
fn.restype = None

def make_input(h, w):
    n = h * w * 3
    b = (ctypes.c_uint8 * n)()
    for i in range(n):
        b[i] = (i * 7 + 13) % 256
    return b

out = (ctypes.c_float * OUT_N)()
ms = (ctypes.c_double * 4)()

for (h, w, iters) in ((224, 224, 200), (481, 321, 100), (1080, 1920, 30)):
    src = make_input(h, w)
    acc = {m: [0.0] * 4 for m in MODES}
    rounds = 3
    for _ in range(rounds):
        for m in MODES:
            for _ in range(2):
                fn(m, src, out, h, w, 1, ms)
            s = [0.0] * 4
            for _ in range(iters):
                fn(m, src, out, h, w, 1, ms)
                for k in range(4):
                    s[k] += ms[k]
            for k in range(4):
                acc[m][k] += s[k] / iters
    print("\n=== %dx%d (1 thread, avg of %d rounds) ===" % (w, h, rounds))
    print("%-20s %10s %10s" % ("clamp mode", "vertical", "total"))
    t = {}
    for m in MODES:
        v = acc[m][2] / rounds
        tot = sum(acc[m]) / rounds
        t[m] = (v, tot)
        print("%-20s %10.3f %10.3f" % (MODES[m], v, tot))
    v0, tot0 = t[0]
    print("-- 差值（相对 full）--")
    print("round+clamp 总成本 : %.3f ms (vertical 的 %.1f%%, 总体的 %.1f%%)" %
          (v0 - t[1][0], 100 * (v0 - t[1][0]) / v0, 100 * (tot0 - t[1][1]) / tot0))
    print("其中 仅钳位(min/max): %.3f ms" % (v0 - t[2][0]))
    print("其中 仅取整(round)  : %.3f ms" % (v0 - t[3][0]))
PY
  ls -l "$D/clamp_neon_opt_clampcost.py"

  echo "== 4. 运行（绑 cpu0）=="
  cd "$D" && taskset -c 0 python3 clamp_neon_opt_clampcost.py ./libpreprocess_clampcost.so 2>&1 | tail -40

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
