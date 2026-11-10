clip_u8_i32 NEON 向量化优化实现记录
日期：2026-10-26
服务器：90.91.147.145（容器 fusionv1）
源码：/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp
参考方案：clip_u8_i32_neon_opt.md

1. 优化目标
resize_bicubic_uint8_fusion 中的 clip_u8_i32 像素钳位循环：

static inline int clip_u8_i32(int x)
{
  return (MIN(255, MAX((x>>PRECISION_BITS), 0)));   // PRECISION_BITS = 22
}
​
原始标量反汇编（每像素 7 条指令，逐像素循环）：

0x420c38  ldr  w0, [x2, x1, lsl #2]    ; 加载 int32
0x420c40  asr  w0, w0, #22             ; 定点右移 22
0x420c44  cmp  w0, #0x0                ; max(v,0)
0x420c48  csel w0, w0, wzr, ge
0x420c4c  cmp  w0, #0xff               ; min(v,255)
0x420c50  csel w0, w0, w7, le
0x420c54  strb w0, [x6, x1]            ; 存 uint8
​
三通道（tmp4 平面 0/1/2 各一遍）共 3 个相同循环。

2. 核心思路：饱和窄化指令吸收钳位
上限恰为 255 时，两段钳位（max/min）完全由饱和窄化指令免费吸收，循环内零比较：

sqxtun（有符号→无符号饱和窄化）：负值钳到 0 → 等价 max(v, 0)
uqxtn（无符号饱和窄化）：超过 255 钳到 255 → 等价 min(v, 255)
3. 源码修改
3.1 新增 NEON 辅助函数（clip_u8_i32 定义之后）
// 16 个 int32 -> 16 个 uint8（饱和窄化吸收 max/min 钳位）
static inline uint8x16_t clip_u8_i32_x16(const int32_t* p) {
    int32x4_t a = vld1q_s32(p + 0);
    int32x4_t b = vld1q_s32(p + 4);
    int32x4_t c = vld1q_s32(p + 8);
    int32x4_t d = vld1q_s32(p + 12);
    a = vshrq_n_s32(a, PRECISION_BITS);
    b = vshrq_n_s32(b, PRECISION_BITS);
    c = vshrq_n_s32(c, PRECISION_BITS);
    d = vshrq_n_s32(d, PRECISION_BITS);
    uint16x8_t lo = vcombine_u16(vqmovun_s32(a), vqmovun_s32(b)); // 负值 -> 0
    uint16x8_t hi = vcombine_u16(vqmovun_s32(c), vqmovun_s32(d));
    return vcombine_u8(vqmovn_u16(lo), vqmovn_u16(hi));            // >255 -> 255
}

// clip + 归一化融合: (clip*scale0-mean)*scale = clip*A + B
static inline void clip_norm_x16(const int32_t* src, float* dst,
                                 float32x4_t vA, float32x4_t vB) {
    const int32x4_t vzero = vdupq_n_s32(0);
    const int32x4_t v255  = vdupq_n_s32(255);
    for (int k = 0; k < 16; k += 4) {
        int32x4_t v = vshrq_n_s32(vld1q_s32(src + k), PRECISION_BITS);
        v = vmaxq_s32(v, vzero);
        v = vminq_s32(v, v255);
        float32x4_t f = vcvtq_f32_s32(v);
        vst1q_f32(dst + k, vfmaq_f32(vB, f, vA));   // f*A + B
    }
}
​
注意：AArch64 正确 intrinsics 名为 vqmovun_s32 / vqmovn_u16；
ARMv7 老名称 vqxtun_s32 / vqxtn_u16 在 aarch64 g++ 下未声明（已踩坑修正）。

3.2 调用点一：单线程 tmp4 分支（原 975-977 行）
{
  // NEON 饱和窄化向量化: 16 像素/次，循环内零比较
  int xx = 0;
  for (; xx + 16 <= dw; xx += 16) {
    vst1q_u8(tmp4 + 0*dh*dw + yy*dw + xx, clip_u8_i32_x16(tmp2 + 2*dw + xx));
    vst1q_u8(tmp4 + 1*dh*dw + yy*dw + xx, clip_u8_i32_x16(tmp2 + 1*dw + xx));
    vst1q_u8(tmp4 + 2*dh*dw + yy*dw + xx, clip_u8_i32_x16(tmp2 + 0*dw + xx));
  }
  for (; xx < dw; xx ++) {          // 标量尾部（dw 非 16 倍数时）
    tmp4[0*dh*dw + yy*dw + xx] = clip_u8_i32(tmp2[2*dw + xx]);
    tmp4[1*dh*dw + yy*dw + xx] = clip_u8_i32(tmp2[1*dw + xx]);
    tmp4[2*dh*dw + yy*dw + xx] = clip_u8_i32(tmp2[0*dw + xx]);
  }
}
​
保持 BGR→RGB 通道交换：输出平面 0 读 tmp2 平面 2，输出平面 2 读平面 0。

3.3 调用点二：多线程 tmp3 分支（原 948-950 行）
clip + 归一化融合，每像素 2 次浮点运算压成 1 条 fmla：

{
  // NEON 向量化: clip + 归一化融合
  const float32x4_t vA0 = vdupq_n_f32(scale0 * scale[0]), vB0 = vdupq_n_f32(-mean[0] * scale[0]);
  const float32x4_t vA1 = vdupq_n_f32(scale0 * scale[1]), vB1 = vdupq_n_f32(-mean[1] * scale[1]);
  const float32x4_t vA2 = vdupq_n_f32(scale0 * scale[2]), vB2 = vdupq_n_f32(-mean[2] * scale[2]);
  int xx = 0;
  for (; xx + 16 <= dw; xx += 16) {
    clip_norm_x16(tmp2 + 2*dw + xx, tmp3 + 0*dw + xx, vA0, vB0);
    clip_norm_x16(tmp2 + 1*dw + xx, tmp3 + 1*dw + xx, vA1, vB1);
    clip_norm_x16(tmp2 + 0*dw + xx, tmp3 + 2*dw + xx, vA2, vB2);
  }
  for (; xx < dw; xx ++) {          // 标量尾部
    tmp3[0*dw + xx] = (clip_u8_i32(tmp2[2*dw + xx]) * scale0 - mean[0]) * scale[0];
    tmp3[1*dw + xx] = (clip_u8_i32(tmp2[1*dw + xx]) * scale0 - mean[1]) * scale[1];
    tmp3[2*dw + xx] = (clip_u8_i32(tmp2[0*dw + xx]) * scale0 - mean[2]) * scale[2];
  }
}
​
4. 编译与运行（benchmark.md 流程）
# 容器 fusionv1 内，目标目录
make clean
make -j
./fusion.unittest 1        # 1 线程
​
编译通过（g++ -O3 --std=c++17 -fopenmp，无警告）。

5. 性能对比
测试尺寸：1080×1920 → 728×1316，单线程，warmup 稳态（Step 9）：

版本	用时/step	带宽	说明
原始（fusion.unittest.bak_before_neon）	12.977 ms	2251.186 MB/s	基线
优化后	11.371 ms	2569.183 MB/s	提速 12.4%
6. 反汇编验证（优化后的 clip 循环）
原标量逐像素序列（ldr→asr→cmp→csel→csel→strb）已消失，替换为向量化循环：

  421018:  ldr  q3, [x1, x15]        ; 一次加载 4×int32
  ...
  421030:  sshr v0.4s, v0.4s, #22    ; 定点右移 ×4
  42103c:  sshr v3.4s, v3.4s, #22
  ...
  421038:  sqxtun v1.4h, v1.4s       ; 负值→0
  421040:  sqxtun v0.4h, v0.4s
  42104c:  sqxtun v3.4h, v3.4s
  421054:  sqxtun v2.4h, v2.4s
  ...
  421060:  uqxtn v1.8b, v1.8h        ; >255→255
  421064:  uqxtn v0.8b, v0.8h
  421068:  stp   d1, d0, [x6]        ; 存 16 字节
  ...
  42110c:  cmp   w5, w10
  421110:  b.ne  421018              ; 16 像素循环
​
循环内零比较，与 clip_u8_i32_neon_opt.md 方案完全一致。

7. 语义等价性保证
vshrq_n_s32(v, 22) 与标量 asr w0, #22 均为算术右移，与 C int >> 22 一致；
vqmovun_s32 饱和窄化：负值→0（等价 max(v,0)）；
vqmovn_u16 饱和窄化：>255→255（等价 min(v,255)）；
结果截断到 8 位与 strb 一致；
16 字节 ld1/st1 支持非对齐访问，各平面按 dw 偏移无需特殊对齐。
8. 文件变更
文件	变更
pillow_fusion_func_v2.cpp	新增 clip_u8_i32_x16/clip_norm_x16；替换 2 处 clip 循环（1028→1078 行）
pillow_fusion_func_v2.cpp.bak_clip_neon	优化前备份
fusion.unittest.bak_before_neon	优化前二进制备份
fusion.unittest	重新编译（1279672 字节）
9. 结论
通过 NEON 饱和窄化指令（sqxtun/uqxtn）吸收像素钳位的 max/min，clip_u8_i32
循环从每像素 7 条标量指令降为每 16 像素约 11 条向量指令（循环内零比较），
单线程 benchmark 提速 12.4%（12.98ms→11.37ms），带宽提升 14%。
