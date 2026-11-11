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
  # 为 v4/v5 补阶段探针，统一直接测量各阶段耗时（不做推算）。

  D=/home/qch/clamp_opt

  echo "== 1. 生成 v4/v5 探针（新文件）=="
  cat > "$D/clamp_neon_opt_probe_v4.cpp" <<'CPP'
// [agent-opt] 生成文件，可安全删除。v4 的分阶段计时。
#include "/home/qch/clamp_opt/clamp_neon_opt_v4.cpp"

extern "C" void probe_stages_v4(const uint8_t* input, float* output,
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
    resize_horizontal_neon4(input, mid, W_in, hp);
    double t2 = v2_now_ms();

    constexpr size_t kResizedBytes = static_cast<size_t>(kOutputPlane) * kInputChannels;
    uint8_t* resized = static_cast<uint8_t*>(checked_alloc(kResizedBytes, 1, "resized"));
    ResizePassParams vp{kOutputSize, kOutputSize, num_threads, &ylut};
    resize_vertical_neon(mid, resized, vp);
    double t3 = v2_now_ms();

    neon_normalize(resized, output, num_threads);
    double t4 = v2_now_ms();

    out_ms[0] = t1 - t0; out_ms[1] = t2 - t1; out_ms[2] = t3 - t2; out_ms[3] = t4 - t3;
    std::free(resized); std::free(mid);
    free_lut(xlut); free_lut(ylut);
}
CPP

  cat > "$D/clamp_neon_opt_probe_v5.cpp" <<'CPP'
// [agent-opt] 生成文件，可安全删除。v5 的分阶段计时。
#include "/home/qch/clamp_opt/clamp_neon_opt_v5.cpp"

extern "C" void probe_stages_v5(const uint8_t* input, float* output,
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
    resize_horizontal_neon_px4(input, mid, W_in, hp);
    double t2 = v2_now_ms();

    constexpr size_t kResizedBytes = static_cast<size_t>(kOutputPlane) * kInputChannels;
    uint8_t* resized = static_cast<uint8_t*>(checked_alloc(kResizedBytes, 1, "resized"));
    ResizePassParams vp{kOutputSize, kOutputSize, num_threads, &ylut};
    resize_vertical_neon(mid, resized, vp);
    double t3 = v2_now_ms();

    neon_normalize(resized, output, num_threads);
    double t4 = v2_now_ms();

    out_ms[0] = t1 - t0; out_ms[1] = t2 - t1; out_ms[2] = t3 - t2; out_ms[3] = t4 - t3;
    std::free(resized); std::free(mid);
    free_lut(xlut); free_lut(ylut);
}
CPP
  ls -l "$D/clamp_neon_opt_probe_v4.cpp" "$D/clamp_neon_opt_probe_v5.cpp"

  echo "== 2. 编译两个探针 =="
  for v in v4 v5; do
    g++ -std=c++14 -march=armv8.2-a+fp16+dotprod -fopenmp -O3 \
        -shared -fPIC -o "$D/libpreprocess_probe_$v.so" "$D/clamp_neon_opt_probe_$v.cpp" 2>&1 | tail -8
    echo "$v build rc=$?"
    ls -l "$D/libpreprocess_probe_$v.so"
  done

  echo "== 3. 生成直接测量脚本（新文件）=="
  cat > "$D/clamp_neon_opt_stage_all.py" <<'PY'
# [agent-opt] 生成文件，可安全删除。直接调用各版本导出的分阶段探针。
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

libs = {
    "v1(base)": load(sys.argv[1], "probe_stages"),
    "v2(vert)": load(sys.argv[2], "probe_stages_v2"),
    "v4(tap4)": load(sys.argv[3], "probe_stages_v4"),
    "v5(px4)":  load(sys.argv[4], "probe_stages_v5"),
}
out = (ctypes.c_float * OUT_N)()
ms = (ctypes.c_double * 4)()

for (h, w, iters) in ((224, 224, 200), (481, 321, 100), (1080, 1920, 30)):
    src = make_input(h, w)
    acc = {k: [0.0] * 4 for k in libs}
    rounds = 3
    for _ in range(rounds):
        for name, fn in libs.items():
            for _ in range(2):
                fn(src, out, h, w, 1, ms)
            s = [0.0] * 4
            for _ in range(iters):
                fn(src, out, h, w, 1, ms)
                for k in range(4):
                    s[k] += ms[k]
            for k in range(4):
                acc[name][k] += s[k] / iters
    print("\n=== %dx%d (1 thread, avg of %d rounds) ===" % (w, h, rounds))
    print("%-10s %8s %11s %9s %10s %8s" %
          ("version", "lut", "horizontal", "vertical", "normalize", "total"))
    for name in libs:
        a = [v / rounds for v in acc[name]]
        print("%-10s %8.3f %11.3f %9.3f %10.3f %8.3f" %
              (name, a[0], a[1], a[2], a[3], sum(a)))
PY
  ls -l "$D/clamp_neon_opt_stage_all.py"

  echo "== 4. 直接测量（绑 cpu0）=="
  cd "$D" && taskset -c 0 python3 clamp_neon_opt_stage_all.py \
      ./libpreprocess_probe.so ./libpreprocess_v2.so \
      ./libpreprocess_probe_v4.so ./libpreprocess_probe_v5.so 2>&1 | tail -30

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
