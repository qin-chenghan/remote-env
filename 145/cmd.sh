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
  # v3：在 v2 基础上，横向 pass 按通道打包向量化（RGB 装进 float32x4）。

  D=/home/qch/clamp_opt

  echo "== 1. 生成 v3 源码（新文件，包含 v2）=="
  cat > "$D/clamp_neon_opt_v3.cpp" <<'CPP'
// [agent-opt] 生成文件，可安全删除。
// v3 = v2(vertical 向量化) + horizontal 按通道打包向量化。
#include "/home/qch/clamp_opt/clamp_neon_opt_v2.cpp"

// 横向：一个像素的 R,G,B 连续 3 字节，装进 float32x4 的第 0..2 lane（第 3 lane 为下一像素的 R，忽略）。
static void resize_horizontal_neon(const uint8_t* input, float* mid, int W_in,
                                   const ResizePassParams& p)
{
    const int stride = p.W_out * kInputChannels;
    const int ymax = (p.H > 1) ? p.H - 1 : 0;   // 最后一行走标量，避免 4 字节读越界
#pragma omp parallel for schedule(static) num_threads(p.num_threads)
    for (int y = 0; y < p.H; ++y) {
        const uint8_t* src = input + y * W_in * kInputChannels;
        float* dst = mid + y * stride;
        const bool vec_row = (y < ymax);

        int vec_end = vec_row ? p.W_out - 1 : 0;   // 最后一个输出像素始终标量
        int x = 0;
        for (; x < vec_end; ++x) {
            int n = p.lut->count[x];
            int xmin = p.lut->start[x];
            const float* w_row = p.lut->w + x * p.lut->ksize;
            const uint8_t* s = src + xmin * kInputChannels;

            float32x4_t acc = vdupq_n_f32(0.0f);
            for (int k = 0; k < n; ++k) {
                uint32_t u;
                __builtin_memcpy(&u, s + k * kInputChannels, 4);
                uint8x8_t vb = vreinterpret_u8_u32(vdup_n_u32(u));
                uint32x4_t w32 = vmovl_u16(vget_low_u16(vmovl_u8(vb)));
                float32x4_t f = vcvtq_f32_u32(w32);
                acc = vfmaq_f32(acc, f, vdupq_n_f32(w_row[k]));
            }
            int32x4_t iv = vcvtaq_s32_f32(acc);
            iv = vmaxq_s32(iv, vdupq_n_s32(0));
            iv = vminq_s32(iv, vdupq_n_s32(255));
            vst1q_f32(dst + x * kInputChannels, vcvtq_f32_s32(iv));
        }
        for (; x < p.W_out; ++x) {                 // 尾部标量（含最后一行）
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

extern "C" void combined_preprocess_v3(const uint8_t* input, float* output,
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
    resize_horizontal_neon(input, mid, W_in, hp);

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
  ls -l "$D/clamp_neon_opt_v3.cpp"

  echo "== 2. 编译 v3 =="
  g++ -std=c++14 -march=armv8.2-a+fp16+dotprod -fopenmp -O3 \
      -shared -fPIC -o "$D/libpreprocess_v3.so" "$D/clamp_neon_opt_v3.cpp" 2>&1 | tail -15
  echo "build rc=$?"
  ls -l "$D/libpreprocess_v3.so"

  echo "== 3. A/B 脚本（新文件）=="
  cat > "$D/clamp_neon_opt_ab3.py" <<'PY'
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
v2 = load(sys.argv[2], "combined_preprocess_v2")
v3 = load(sys.argv[3], "combined_preprocess_v3")

print("%-12s %-4s %9s %9s %9s %8s %8s %8s" %
      ("size", "thr", "v1", "v2", "v3", "v1/v2", "v1/v3", "v3 match"))
for (h, w, iters) in ((224, 224, 200), (481, 321, 100), (1080, 1920, 30)):
    for t in (1, 4):
        m1, b1 = run(v1, h, w, t, iters)
        m2, b2 = run(v2, h, w, t, iters)
        m3, b3 = run(v3, h, w, t, iters)
        same = "exact" if b1 == b3 else "DIFF"
        print("%-12s %-4d %9.3f %9.3f %9.3f %7.2fx %7.2fx %8s" %
              ("%dx%d" % (w, h), t, m1, m2, m3, m1 / m2, m1 / m3, same))
PY
  ls -l "$D/clamp_neon_opt_ab3.py"

  echo "== 4. A/B 运行（绑 cpu0）=="
  cd "$D" && taskset -c 0 python3 clamp_neon_opt_ab3.py ./libpreprocess.so ./libpreprocess_v2.so ./libpreprocess_v3.so 2>&1 | tail -12

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
