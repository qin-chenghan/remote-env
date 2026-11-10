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
  # v4：横向用 4 个独立累加器打断 FMA 依赖链 + 批量加载权重。

  D=/home/qch/clamp_opt

  echo "== 1. 生成 v4 源码（新文件，包含 v2）=="
  cat > "$D/clamp_neon_opt_v4.cpp" <<'CPP'
// [agent-opt] 生成文件，可安全删除。
// v4 = v2(vertical 向量化) + horizontal 按通道打包且用 4 个累加器打断依赖链。
#include "/home/qch/clamp_opt/clamp_neon_opt_v2.cpp"

static inline float32x4_t load_rgb4(const uint8_t* p) {
    uint32_t u;
    __builtin_memcpy(&u, p, 4);
    uint8x8_t vb = vreinterpret_u8_u32(vdup_n_u32(u));
    return vcvtq_f32_u32(vmovl_u16(vget_low_u16(vmovl_u8(vb))));
}

static void resize_horizontal_neon4(const uint8_t* input, float* mid, int W_in,
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

        int x = 0;
        for (; x < vec_end; ++x) {
            int n = p.lut->count[x];
            int xmin = p.lut->start[x];
            const float* w_row = p.lut->w + x * p.lut->ksize;
            const uint8_t* s = src + xmin * kInputChannels;

            float32x4_t a0 = vdupq_n_f32(0.0f), a1 = vdupq_n_f32(0.0f);
            float32x4_t a2 = vdupq_n_f32(0.0f), a3 = vdupq_n_f32(0.0f);

            int k = 0;
            for (; k + 4 <= n; k += 4) {          // 4 条独立链
                float32x4_t w4 = vld1q_f32(w_row + k);
                a0 = vfmaq_laneq_f32(a0, load_rgb4(s + (k + 0) * kInputChannels), w4, 0);
                a1 = vfmaq_laneq_f32(a1, load_rgb4(s + (k + 1) * kInputChannels), w4, 1);
                a2 = vfmaq_laneq_f32(a2, load_rgb4(s + (k + 2) * kInputChannels), w4, 2);
                a3 = vfmaq_laneq_f32(a3, load_rgb4(s + (k + 3) * kInputChannels), w4, 3);
            }
            for (; k < n; ++k) {
                a0 = vfmaq_n_f32(a0, load_rgb4(s + k * kInputChannels), w_row[k]);
            }

            float32x4_t acc = vaddq_f32(vaddq_f32(a0, a1), vaddq_f32(a2, a3));
            int32x4_t iv = vcvtaq_s32_f32(acc);
            iv = vmaxq_s32(iv, vdupq_n_s32(0));
            iv = vminq_s32(iv, vdupq_n_s32(255));
            vst1q_f32(dst + x * kInputChannels, vcvtq_f32_s32(iv));
        }
        for (; x < p.W_out; ++x) {
            int n = p.lut->count[x];
            int xmin = p.lut->start[x];
            const float* w_row = p.lut->w + x * p.lut->ksize;
            float R = 0.0f, G = 0.0f, B = 0.0f;
            for (int k = 0; k < n; ++k) {
                int off = (xmin + k) * kInputChannels;
                float wk = w_row[k];
                R += static_cast<float>(src[off + kChannelR]) * wk;
                G += static_cast<float>(src[off + kChannelG]) * wk;
                B += static_cast<float>(src[off + kChannelB]) * wk;
            }
            dst[x * kInputChannels + kChannelR] =
                std::max(0.0f, std::min(kUint8ToFloatDivisor, std::round(R)));
            dst[x * kInputChannels + kChannelG] =
                std::max(0.0f, std::min(kUint8ToFloatDivisor, std::round(G)));
            dst[x * kInputChannels + kChannelB] =
                std::max(0.0f, std::min(kUint8ToFloatDivisor, std::round(B)));
        }
    }
}

extern "C" void combined_preprocess_v4(const uint8_t* input, float* output,
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
    resize_horizontal_neon4(input, mid, W_in, hp);

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
  ls -l "$D/clamp_neon_opt_v4.cpp"

  echo "== 2. 编译 v4 =="
  g++ -std=c++14 -march=armv8.2-a+fp16+dotprod -fopenmp -O3 \
      -shared -fPIC -o "$D/libpreprocess_v4.so" "$D/clamp_neon_opt_v4.cpp" 2>&1 | tail -15
  echo "build rc=$?"
  ls -l "$D/libpreprocess_v4.so"

  echo "== 3. A/B 脚本（新文件）=="
  cat > "$D/clamp_neon_opt_ab4.py" <<'PY'
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
    return ms, memoryview(out).tobytes()

v1 = load(sys.argv[1], "combined_preprocess")
v3 = load(sys.argv[2], "combined_preprocess_v3")
v4 = load(sys.argv[3], "combined_preprocess_v4")

print("%-12s %-4s %9s %9s %9s %8s %8s %8s" %
      ("size", "thr", "v1", "v3", "v4", "v1/v3", "v1/v4", "match"))
for (h, w, iters) in ((224, 224, 200), (481, 321, 100), (1080, 1920, 30)):
    for t in (1, 4):
        m1, b1 = run(v1, h, w, t, iters)
        m3, b3 = run(v3, h, w, t, iters)
        m4, b4 = run(v4, h, w, t, iters)
        same = "exact" if b1 == b4 else "DIFF"
        print("%-12s %-4d %9.3f %9.3f %9.3f %7.2fx %7.2fx %8s" %
              ("%dx%d" % (w, h), t, m1, m3, m4, m1 / m3, m1 / m4, same))
PY
  ls -l "$D/clamp_neon_opt_ab4.py"

  echo "== 4. A/B 运行（绑 cpu0）=="
  cd "$D" && taskset -c 0 python3 clamp_neon_opt_ab4.py ./libpreprocess.so ./libpreprocess_v3.so ./libpreprocess_v4.so 2>&1 | tail -12

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
