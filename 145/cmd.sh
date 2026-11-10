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
  # v5：4 个输出像素并行（每像素保持原始累加顺序 -> 逐字节等价）。

  D=/home/qch/clamp_opt

  echo "== 1. 生成 v5 源码（新文件，包含 v2）=="
  cat > "$D/clamp_neon_opt_v5.cpp" <<'CPP'
// [agent-opt] 生成文件，可安全删除。
// v5 = v2(vertical 向量化) + horizontal 4 像素并行（保持原累加顺序，结果 bit-exact）。
#include "/home/qch/clamp_opt/clamp_neon_opt_v2.cpp"

static inline float32x4_t load_rgb4(const uint8_t* p) {
    uint32_t u;
    __builtin_memcpy(&u, p, 4);
    uint8x8_t vb = vreinterpret_u8_u32(vdup_n_u32(u));
    return vcvtq_f32_u32(vmovl_u16(vget_low_u16(vmovl_u8(vb))));
}

static inline void store_clamped(float* dst, float32x4_t acc) {
    int32x4_t iv = vcvtaq_s32_f32(acc);
    iv = vmaxq_s32(iv, vdupq_n_s32(0));
    iv = vminq_s32(iv, vdupq_n_s32(255));
    vst1q_f32(dst, vcvtq_f32_s32(iv));
}

static void resize_horizontal_neon_px4(const uint8_t* input, float* mid, int W_in,
                                       const ResizePassParams& p)
{
    const int stride = p.W_out * kInputChannels;
    const int ymax = (p.H > 1) ? p.H - 1 : 0;
#pragma omp parallel for schedule(static) num_threads(p.num_threads)
    for (int y = 0; y < p.H; ++y) {
        const uint8_t* src = input + y * W_in * kInputChannels;
        float* dst = mid + y * stride;
        const bool vec_row = (y < ymax);
        int vec_end = vec_row ? p.W_out - 1 : 0;

        auto scalar_pixel = [&](int xx) {
            int n = p.lut->count[xx];
            int xmin = p.lut->start[xx];
            const float* w_row = p.lut->w + xx * p.lut->ksize;
            float R = 0.0f, G = 0.0f, B = 0.0f;
            for (int k = 0; k < n; ++k) {
                int off = (xmin + k) * kInputChannels;
                float wk = w_row[k];
                R += static_cast<float>(src[off + kChannelR]) * wk;
                G += static_cast<float>(src[off + kChannelG]) * wk;
                B += static_cast<float>(src[off + kChannelB]) * wk;
            }
            dst[xx * kInputChannels + kChannelR] =
                std::max(0.0f, std::min(kUint8ToFloatDivisor, std::round(R)));
            dst[xx * kInputChannels + kChannelG] =
                std::max(0.0f, std::min(kUint8ToFloatDivisor, std::round(G)));
            dst[xx * kInputChannels + kChannelB] =
                std::max(0.0f, std::min(kUint8ToFloatDivisor, std::round(B)));
        };

        int x = 0;
        for (; x + 4 <= vec_end; x += 4) {
            int n0 = p.lut->count[x], n1 = p.lut->count[x + 1];
            int n2 = p.lut->count[x + 2], n3 = p.lut->count[x + 3];
            if (n0 != n1 || n1 != n2 || n2 != n3) {   // tap 数不一致时退回标量
                scalar_pixel(x); scalar_pixel(x + 1);
                scalar_pixel(x + 2); scalar_pixel(x + 3);
                continue;
            }
            const uint8_t* s0 = src + p.lut->start[x] * kInputChannels;
            const uint8_t* s1 = src + p.lut->start[x + 1] * kInputChannels;
            const uint8_t* s2 = src + p.lut->start[x + 2] * kInputChannels;
            const uint8_t* s3 = src + p.lut->start[x + 3] * kInputChannels;
            const float* w0 = p.lut->w + x * p.lut->ksize;
            const float* w1 = p.lut->w + (x + 1) * p.lut->ksize;
            const float* w2 = p.lut->w + (x + 2) * p.lut->ksize;
            const float* w3 = p.lut->w + (x + 3) * p.lut->ksize;

            float32x4_t a0 = vdupq_n_f32(0.0f), a1 = vdupq_n_f32(0.0f);
            float32x4_t a2 = vdupq_n_f32(0.0f), a3 = vdupq_n_f32(0.0f);
            for (int k = 0; k < n0; ++k) {           // 每个像素的累加顺序与原版一致
                a0 = vfmaq_n_f32(a0, load_rgb4(s0 + k * kInputChannels), w0[k]);
                a1 = vfmaq_n_f32(a1, load_rgb4(s1 + k * kInputChannels), w1[k]);
                a2 = vfmaq_n_f32(a2, load_rgb4(s2 + k * kInputChannels), w2[k]);
                a3 = vfmaq_n_f32(a3, load_rgb4(s3 + k * kInputChannels), w3[k]);
            }
            store_clamped(dst + (x + 0) * kInputChannels, a0);
            store_clamped(dst + (x + 1) * kInputChannels, a1);
            store_clamped(dst + (x + 2) * kInputChannels, a2);
            store_clamped(dst + (x + 3) * kInputChannels, a3);
        }
        for (; x < p.W_out; ++x) scalar_pixel(x);
    }
}

extern "C" void combined_preprocess_v5(const uint8_t* input, float* output,
                                       int H_in, int W_in, int num_threads)
{
    Lut xlut = build_lut(kOutputSize, W_in);
    Lut ylut = build_lut(kOutputSize, H_in);
    const int stride = kOutputSize * kInputChannels;
    float* mid = static_cast<float*>(
        checked_alloc(static_cast<size_t>(H_in) * static_cast<size_t>(stride),
                      sizeof(float), "mid"));
    ResizePassParams hp{H_in, kOutputSize, num_threads, &xlut};
    ResizePassParams vp{kOutputSize, kOutputSize, num_threads, &ylut};
    resize_horizontal_neon_px4(input, mid, W_in, hp);

    constexpr size_t kResizedBytes = static_cast<size_t>(kOutputPlane) * kInputChannels;
    uint8_t* resized = static_cast<uint8_t*>(checked_alloc(kResizedBytes, 1, "resized"));
    resize_vertical_neon(mid, resized, vp);

    neon_normalize(resized, output, num_threads);
    std::free(resized);
    std::free(mid);
    free_lut(xlut);
    free_lut(ylut);
}
CPP
  ls -l "$D/clamp_neon_opt_v5.cpp"

  echo "== 2. 编译 v5 =="
  g++ -std=c++14 -march=armv8.2-a+fp16+dotprod -fopenmp -O3 \
      -shared -fPIC -o "$D/libpreprocess_v5.so" "$D/clamp_neon_opt_v5.cpp" 2>&1 | tail -15
  echo "build rc=$?"
  ls -l "$D/libpreprocess_v5.so"

  echo "== 3. A/B 脚本（含最大误差，新文件）=="
  cat > "$D/clamp_neon_opt_ab5.py" <<'PY'
# [agent-opt] 生成文件，可安全删除。
import ctypes, sys, time

OUT_N = 6 * 224 * 224

def load(path, name):
    lib = ctypes.CDLL(path)
    fn = getattr(lib, name)
    fn.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(ctypes.c_float),
                   ctypes.c_int, ctypes.c_int, ctypes.c_int]
    fn.restype = None
    return fn

def make_input(h, w):
    n = h * w * 3
    b = (ctypes.c_uint8 * n)()
    for i in range(n):
        b[i] = (i * 7 + 13) % 256
    return b

def run(fn, h, w, threads, iters):
    src = make_input(h, w)
    out = (ctypes.c_float * OUT_N)()
    for _ in range(3):
        fn(src, out, h, w, threads)
    t0 = time.perf_counter()
    for _ in range(iters):
        fn(src, out, h, w, threads)
    ms = (time.perf_counter() - t0) / iters * 1000
    return ms, out

def maxdiff(a, b):
    return max(abs(a[i] - b[i]) for i in range(OUT_N))

v1 = load(sys.argv[1], "combined_preprocess")
v4 = load(sys.argv[2], "combined_preprocess_v4")
v5 = load(sys.argv[3], "combined_preprocess_v5")

print("%-12s %-4s %9s %9s %9s %8s %8s %-12s %-12s" %
      ("size", "thr", "v1", "v4", "v5", "v1/v4", "v1/v5", "v4 diff", "v5 diff"))
for (h, w, iters) in ((224, 224, 200), (481, 321, 100), (1080, 1920, 30)):
    for t in (1, 4):
        m1, o1 = run(v1, h, w, t, iters)
        m4, o4 = run(v4, h, w, t, iters)
        m5, o5 = run(v5, h, w, t, iters)
        d4 = maxdiff(o1, o4)
        d5 = maxdiff(o1, o5)
        print("%-12s %-4d %9.3f %9.3f %9.3f %7.2fx %7.2fx %-12.3e %-12.3e" %
              ("%dx%d" % (w, h), t, m1, m4, m5, m1 / m4, m1 / m5, d4, d5))
PY
  ls -l "$D/clamp_neon_opt_ab5.py"

  echo "== 4. A/B 运行（绑 cpu0）=="
  cd "$D" && taskset -c 0 python3 clamp_neon_opt_ab5.py ./libpreprocess.so ./libpreprocess_v4.so ./libpreprocess_v5.so 2>&1 | tail -12

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
