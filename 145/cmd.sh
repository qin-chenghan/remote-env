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
  # 新建 v2 实现（#include 原文件，不改原文件）：vertical pass 向量化 + clamp 融合。

  D=/home/qch/clamp_opt

  echo "== 1. 生成 v2 源码（新文件）=="
  cat > "$D/clamp_neon_opt_v2.cpp" <<'CPP'
// [agent-opt] 生成文件，可安全删除。v2: resize_vertical 按 x 向量化，clamp 由饱和窄化吸收。
#include "/home/qch/projects/vllm/workplace/lib_preprocess.cpp"
#include <chrono>

static inline double v2_now_ms() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

// 8 个 float -> 8 个 uint8：round(ties away) + clamp[0,255]
static inline uint8x8_t clamp_u8_x8(float32x4_t lo, float32x4_t hi) {
    int32x4_t ilo = vcvtaq_s32_f32(lo);      // std::round 等价（.5 远离零）
    int32x4_t ihi = vcvtaq_s32_f32(hi);
    uint16x8_t u16 = vcombine_u16(vqmovun_s32(ilo), vqmovun_s32(ihi));  // 负 -> 0
    return vqmovn_u16(u16);                                             // >255 -> 255
}

static void resize_vertical_neon(const float* mid, uint8_t* output,
                                 const ResizePassParams& p)
{
    const int stride = p.W_out * kInputChannels;
#pragma omp parallel for schedule(static) num_threads(p.num_threads)
    for (int y = 0; y < p.H; ++y) {
        uint8_t* dst = output + y * p.W_out * kInputChannels;
        int n = p.lut->count[y];
        int ymin = p.lut->start[y];
        const float* w_row = p.lut->w + y * p.lut->ksize;

        int x = 0;
        for (; x + 8 <= p.W_out; x += 8) {
            float32x4_t rlo = vdupq_n_f32(0.0f), rhi = vdupq_n_f32(0.0f);
            float32x4_t glo = vdupq_n_f32(0.0f), ghi = vdupq_n_f32(0.0f);
            float32x4_t blo = vdupq_n_f32(0.0f), bhi = vdupq_n_f32(0.0f);
            const float* base = mid + ymin * stride + x * kInputChannels;
            for (int k = 0; k < n; ++k) {
                float32x4x3_t a = vld3q_f32(base + k * stride);
                float32x4x3_t b = vld3q_f32(base + k * stride + 4 * kInputChannels);
                float32x4_t wk = vdupq_n_f32(w_row[k]);
                rlo = vfmaq_f32(rlo, a.val[kChannelR], wk);
                glo = vfmaq_f32(glo, a.val[kChannelG], wk);
                blo = vfmaq_f32(blo, a.val[kChannelB], wk);
                rhi = vfmaq_f32(rhi, b.val[kChannelR], wk);
                ghi = vfmaq_f32(ghi, b.val[kChannelG], wk);
                bhi = vfmaq_f32(bhi, b.val[kChannelB], wk);
            }
            uint8x8x3_t out;
            out.val[kChannelR] = clamp_u8_x8(rlo, rhi);
            out.val[kChannelG] = clamp_u8_x8(glo, ghi);
            out.val[kChannelB] = clamp_u8_x8(blo, bhi);
            vst3_u8(dst + x * kInputChannels, out);
        }
        for (; x < p.W_out; ++x) {           // 尾部不足 8 像素走标量
            float R = 0.0f, G = 0.0f, B = 0.0f;
            for (int k = 0; k < n; ++k) {
                const float* src_row = mid + (ymin + k) * stride + x * kInputChannels;
                float wk = w_row[k];
                R += src_row[kChannelR] * wk;
                G += src_row[kChannelG] * wk;
                B += src_row[kChannelB] * wk;
            }
            int off = x * kInputChannels;
            dst[off + kChannelR] = clamp_to_u8(R);
            dst[off + kChannelG] = clamp_to_u8(G);
            dst[off + kChannelB] = clamp_to_u8(B);
        }
    }
}

// v2 入口：除 vertical 外与原版完全一致
extern "C" void combined_preprocess_v2(const uint8_t* input, float* output,
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
    resize_horizontal(input, mid, W_in, hp);

    constexpr size_t kResizedBytes = static_cast<size_t>(kOutputPlane) * kInputChannels;
    uint8_t* resized = static_cast<uint8_t*>(checked_alloc(kResizedBytes, 1, "resized"));
    resize_vertical_neon(mid, resized, vp);

    neon_normalize(resized, output, num_threads);
    std::free(resized);
    std::free(mid);
    free_lut(xlut);
    free_lut(ylut);
}

// 分阶段计时（v2），用于确认收益来自 vertical
extern "C" void probe_stages_v2(const uint8_t* input, float* output,
                                int H_in, int W_in, int num_threads, double* out_ms)
{
    double t0 = v2_now_ms();
    Lut xlut = build_lut(kOutputSize, W_in);
    Lut ylut = build_lut(kOutputSize, H_in);
    const int stride = kOutputSize * kInputChannels;
    float* mid = static_cast<float*>(
        checked_alloc(static_cast<size_t>(H_in) * static_cast<size_t>(stride),
                      sizeof(float), "mid"));
    double t1 = v2_now_ms();

    ResizePassParams hp{H_in, kOutputSize, num_threads, &xlut};
    resize_horizontal(input, mid, W_in, hp);
    double t2 = v2_now_ms();

    constexpr size_t kResizedBytes = static_cast<size_t>(kOutputPlane) * kInputChannels;
    uint8_t* resized = static_cast<uint8_t*>(checked_alloc(kResizedBytes, 1, "resized"));
    ResizePassParams vp{kOutputSize, kOutputSize, num_threads, &ylut};
    resize_vertical_neon(mid, resized, vp);
    double t3 = v2_now_ms();

    neon_normalize(resized, output, num_threads);
    double t4 = v2_now_ms();

    out_ms[0] = t1 - t0; out_ms[1] = t2 - t1; out_ms[2] = t3 - t2; out_ms[3] = t4 - t3;
    std::free(resized);
    std::free(mid);
    free_lut(xlut);
    free_lut(ylut);
}
CPP
  ls -l "$D/clamp_neon_opt_v2.cpp"

  echo "== 2. 编译 v2 =="
  g++ -std=c++14 -march=armv8.2-a+fp16+dotprod -fopenmp -O3 \
      -shared -fPIC -o "$D/libpreprocess_v2.so" "$D/clamp_neon_opt_v2.cpp" 2>&1 | tail -15
  echo "build rc=$?"
  ls -l "$D/libpreprocess_v2.so"

  echo "== 3. 生成 A/B 脚本（新文件）=="
  cat > "$D/clamp_neon_opt_ab.py" <<'PY'
# [agent-opt] 生成文件，可安全删除。逐字节比对 v1/v2 输出并计时。
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
v2 = load(sys.argv[2], "combined_preprocess_v2")

print("%-12s %-4s %10s %10s %8s %10s" % ("size", "thr", "v1_ms", "v2_ms", "speedup", "match"))
for (h, w, iters) in ((224, 224, 200), (481, 321, 100), (1080, 1920, 30)):
    for t in (1, 4):
        ms1, b1 = run(v1, h, w, t, iters)
        ms2, b2 = run(v2, h, w, t, iters)
        same = "exact" if b1 == b2 else "DIFF"
        print("%-12s %-4d %10.3f %10.3f %8.2fx %10s" %
              ("%dx%d" % (w, h), t, ms1, ms2, ms1 / ms2 if ms2 else 0, same))
PY
  ls -l "$D/clamp_neon_opt_ab.py"

  echo "== 4. A/B 对比（绑 cpu0）=="
  cd "$D" && taskset -c 0 python3 clamp_neon_opt_ab.py ./libpreprocess.so ./libpreprocess_v2.so 2>&1 | tail -12

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
