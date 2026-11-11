# clamp_to_u8 / resize_vertical NEON 向量化优化实现记录

日期：2026-11-11
机器：145（openEuler 24.03 SP3，Kunpeng 920 7270Z，aarch64）
源码：`boostkit/vllm` 分支 `openvla-neon-preprocess`，`workplace/lib_preprocess.cpp`
约束：只在新建文件中实现，原文件一字未改；以 bit-exact（无损）为验收标准

---

## 1. 优化对象

`lib_preprocess.cpp` 是 OpenVLA 图像前处理的独立 `.so`，入口 `combined_preprocess()`，
被 Python 通过 ctypes 调用。流程分三段：

```
bicubic_resize()
├── resize_horizontal()   横向缩放，W_in → 224，uint8 输入 → float 中间图 mid
└── resize_vertical()     纵向缩放，H_in → 224，mid → uint8 输出
    └── 每像素 3 次 clamp_to_u8()   ← clamp 的唯一调用点
neon_normalize()          6 路输出（DINOv2 3 + SigLIP 3），原本已是 NEON
```

`clamp_to_u8`（第 245 行）：

```cpp
static inline uint8_t clamp_to_u8(float v) {
    return static_cast<uint8_t>(
        std::max(0.0f, std::min(kUint8ToFloatDivisor, std::round(v)));
}
// kUint8ToFloatDivisor = 255.0f
```

语义 = 四舍五入（`.5` 远离零）→ 钳位 [0,255] → 转 8 位整数。

---

## 2. 关键观察：clamp 不能单独优化

`resize_vertical` 内层是**逐像素**的标量循环：

```cpp
for (int x = 0; x < p.W_out; ++x) {
    float R = 0, G = 0, B = 0;
    for (int k = 0; k < n; ++k) {            // n 个 tap 加权累加
        R += mid[...] * w_row[k];  G += ...;  B += ...;
    }
    dst[off+0] = clamp_to_u8(R);
    dst[off+1] = clamp_to_u8(G);
    dst[off+2] = clamp_to_u8(B);
}
```

每个像素只有 3 个 clamp 调用。若只把这 3 个标量 clamp 换成 SIMD，
向量寄存器利用率极低（3 个值/16 lane），**收益接近零**。
要榨出收益，必须同时把累加循环向量化，让 clamp 成为向量循环的收尾。

这里有一个对向量化极其有利的前提：
**`n`、`ymin`、权重 `w_row` 只依赖 y，同一行内所有 x 完全相同。**

---

## 3. 向量化实现（v2：vertical pass）

按 x 方向一次处理 **8 个像素**：

```cpp
// 8 个 float → 8 个 uint8：round(ties away) + clamp[0,255]
static inline uint8x8_t clamp_u8_x8(float32x4_t lo, float32x4_t hi) {
    int32x4_t ilo = vcvtaq_s32_f32(lo);   // == std::round（.5 远离零）
    int32x4_t ihi = vcvtaq_s32_f32(hi);
    uint16x8_t u16 = vcombine_u16(vqmovun_s32(ilo), vqmovun_s32(ihi)); // 负 → 0
    return vqmovn_u16(u16);                                          // >255 → 255
}

for (; x + 8 <= p.W_out; x += 8) {
    float32x4_t rlo = vdupq_n_f32(0), rhi = vdupq_n_f32(0);        // 每通道 2 个累加器
    float32x4_t glo = 0, ghi = 0, blo = 0, bhi = 0;
    const float* base = mid + ymin * stride + x * kInputChannels;
    for (int k = 0; k < n; ++k) {
        float32x4x3_t a = vld3q_f32(base + k * stride);            // 4 像素 RGB
        float32x4x3_t b = vld3q_f32(base + k * stride + 4*kInputChannels);
        float32x4_t wk = vdupq_n_f32(w_row[k]);
        rlo = vfmaq_f32(rlo, a.val[R], wk);  rhi = vfmaq_f32(rhi, b.val[R], wk);
        glo = vfmaq_f32(glo, a.val[G], wk);  ghi = vfmaq_f32(ghi, b.val[G], wk);
        blo = vfmaq_f32(blo, a.val[B], wk);  bhi = vfmaq_f32(bhi, b.val[B], wk);
    }
    uint8x8x3_t out;
    out.val[R] = clamp_u8_x8(rlo, rhi);
    out.val[G] = clamp_u8_x8(glo, ghi);
    out.val[B] = clamp_u8_x8(blo, bhi);
    vst3_u8(dst + x * kInputChannels, out);                        // 一次写 24 字节
}
// 尾部不足 8 像素走原标量逻辑
```

三个要点：

1. **`vld3q_f32` 做去交错**：`mid` 是 RGB 交错的 float，一次加载取出 4 像素的三通道，
   每 tap 2 次 load 覆盖 8 像素。
2. **每 tap 6 条 `vfmaq`**（3 通道 × 2 向量）完成 24 次乘加，标量需要 24 条。
3. **round 和钳位被饱和窄化吸收**：
   - `vcvtaq_s32_f32` = ARM `FCVTAS` = 四舍五入且 `.5` 远离零，**与 `std::round` 精确一致**
     （不能用 `vcvtnq`，那是 ties-to-even，`0.5` 会舍成 `0`）
   - `vqmovun_s32`：负数饱和到 0 → 等价 `max(v, 0)`
   - `vqmovn_u16`：超过 255 饱和到 255 → 等价 `min(v, 255)`

   因此 clamp 的三条标量指令（round + max + min）在向量路径中**没有额外成本**。

### 语义等价性

- `vcvtaq` 饱和转换：超范围输入饱和到 INT32 边界，后续窄化仍得 0/255，与标量一致
- 中间累加值为整数（`mid` 由横向 pass 取整后存入），浮点加法顺序与标量完全相同
- 实测 3 种尺寸 × 1/4 线程，输出与基线**逐字节一致**

---

## 4. 收益数据（直接测量，非推算）

方法：库内导出 `probe_stages*`，把 `LUT构建/分配 → horizontal → vertical → normalize`
分别用 `steady_clock` 包住；1 线程，`taskset -c 0`，3 轮取平均。

### 4.1 各阶段原始耗时（v1 基线）

| 尺寸 | lut | horizontal | vertical | normalize | 合计 |
|---|---|---|---|---|---|
| 224×224 | 0.007 | 0.355 | 0.326 | 0.078 | 0.766 |
| 321×481 | 0.011 | 1.029 | 0.465 | 0.082 | 1.587 |
| 1920×1080 | 0.039 | 8.789 | 0.975 | 0.089 | 9.892 |

（单位 ms）

### 4.2 vertical 阶段优化前后

| 尺寸 | v1 | v2 | 加速 |
|---|---|---|---|
| 224×224 | 0.326 | **0.087** | **3.75×** |
| 321×481 | 0.465 | **0.178** | **2.61×** |
| 1920×1080 | 0.975 | **0.483** | **2.02×** |

### 4.3 端到端（库入口，无损）

| 尺寸 | v1 | v2 | 提升 |
|---|---|---|---|
| 224×224 | 0.766 | 0.525 | 1.46× |
| 321×481 | 1.587 | 1.300 | 1.22× |
| 1920×1080 | 9.892 | 9.404 | 1.05× |

---

## 5. clamp 单独的成本剥离实验

为了精确回答「clamp 本身值多少」，构造四种只改 clamp 语义的版本，其余代码完全相同：

| 模式 | vertical (224) | vertical (481×321) | vertical (1080p) |
|---|---|---|---|
| full（round + min/max） | 0.325 | 0.465 | 0.911 |
| cast only（无 round、无钳位） | 0.199 | 0.372 | 0.826 |
| round only（去掉 min/max） | 0.197 | 0.365 | 0.824 |
| clamp only（去掉 round） | 0.322 | 0.455 | 0.876 |

推导：

| 尺寸 | round+clamp 总成本 | 占端到端 | 其中钳位 | 其中 round |
|---|---|---|---|---|
| 224×224 | 0.126 ms | **16.2%** | 0.128 ms | 0.003 ms |
| 481×321 | 0.093 ms | 5.5% | 0.100 ms | 0.010 ms |
| 1920×1080 | 0.085 ms | **1.1%** | 0.086 ms | 0.035 ms |

两个明确结论：

1. **成本几乎全在钳位（min/max）**，`std::round` 近乎免费
   （`round only` 0.197 ≈ `cast only` 0.199，gcc 把 `frinta` 融得极便宜）
2. **单独优化 clamp 的端到端上限只有 16.2% / 5.5% / 1.1%**
   → 实际 vertical 的 3.75×/2.61×/2.02× **主要来自累加循环向量化**，clamp 只是被顺带吸收

---

## 6. 为什么图像越大，收益越小

这是最容易被质疑的一点，原因有三层，且都能用数据验证。

### 6.1 工作量结构变化：输出固定，filter 工作随输入增长

输出永远是 224×224。图变大只增加「每个输出像素吃多少行/列」：

| 输入 | 水平收缩倍率 | 每像素 tap 数 n |
|---|---|---|
| 224×224 | 1.0 | ≈4 |
| 321×481 | 1.43 | ≈6–7 |
| 1920×1080 | 8.57 | ≈35 |

于是时间分布从「三段均衡」变成「horizontal 独大」：

| 尺寸 | horizontal 占比 | vertical 占比 |
|---|---|---|
| 224×224 | 46% | 42% |
| 321×481 | 65% | 29% |
| 1920×1080 | **89%** | 9% |

**clamp 和 normalize 都是「每个输出像素固定一次」的成本，被稀释**；
而我们优化的 vertical 在大图里只剩 9%，上限本来就只有这么多。

### 6.2 clamp 在 vertical 内的占比也随 n 下降

标量每像素的指令构成（单线程、n 个 tap、3 通道）：

```
累加：n × 3 次 (load + cvt + FMA) ≈ 6n ~ 9n 条
clamp：3 × (round + max + min + cvt + store) ≈ 15 条   ← 固定，与 n 无关
```

| n | clamp 占 vertical 比例 | 占端到端 |
|---|---|---|
| 4（224×224） | ≈38% | ≈16% |
| 6–7（481×321） | ≈28% | ≈5.5% |
| 35（1080p） | ≈7% | ≈1.1% |

**n 越大，clamp 的固定成本被累加工作淹没。**

### 6.3 vertical 自身的加速比也随 n 下降（3.75× → 2.02×）

向量循环里，同一通道的每条 `vfmaq` 依赖上一 tap 的结果，形成依赖链；
n 越长，AArch64 FMA 的 3–4 周期延迟越难被掩盖。
n=4 时链条短、可被循环开销掩盖；n≈20（1080p 的 vertical）时延迟暴露，
所以阶段加速从 3.75× 掉到 2.02×。

> 同理，横向 pass 的 35 个 tap 是更长的链——这也是后面横向优化收效有限的原因。

### 6.4 最关键的：大图瓶颈转移到 horizontal，而它最难向量化

1080p 下 89% 的时间在横向。横向的结构比纵向难：

- `n`、`xmin`、权重 **逐输出像素不同**，不能像纵向那样按 x 批量
- 源数据是 uint8 交错 RGB，3 字节步长与 4 lane 不对齐
- 要乘 float 权重，必须先 `u8→u16→u32→f32` 三次宽化，**3–4 条指令/tap 的开销**
- 4 lane 里只有 3 个承载 R/G/B，**有效利用率 75%**

实测三种横向方案（1 线程）：

| 尺寸 | v1 横向 | 通道打包 | 按 tap 拆 4 累加器 | 按像素拆 4 累加器 |
|---|---|---|---|---|
| 224×224 | 0.355 | — | 0.333（1.07×） | **0.245（1.45×）** |
| 321×481 | 1.029 | — | 0.931（1.11×） | 1.008（1.02×） |
| 1920×1080 | 8.789 | — | **7.663（1.15×）** | 8.819（**1.00×，无收益**） |

能拿到 1.15× 的「按 tap 拆累加器」方案，代价是**改变浮点求和顺序 → 1 个色阶差异**，
不符合无损要求，因此未采用。

---

## 7. 结论与适用边界

1. **clamp 本身不是可独立优化的热点**：它的成本几乎全是 `min/max`，端到端上限 16.2%/5.5%/1.1%
2. **收益来自把 vertical 的累加循环向量化**，clamp 由饱和窄化顺带吸收，零额外成本
3. **无损方案（v2）的阶段级收益**：vertical 3.75× / 2.61× / 2.02×，端到端 1.46× / 1.22× / 1.05×
4. **收益随图变大递减是结构性的**，不是实现问题：
   - 输出尺寸固定 → clamp/normalize 的固定成本被稀释
   - n 增大 → clamp 占比从 38% 降到 7%
   - 依赖链变长 → vertical 自身加速从 3.75× 降到 2.02×
   - 瓶颈转移到最难的 horizontal（89%）
5. **横向进一步优化需要算法级改动**（定点/半精度减少宽化、相邻输出共享窗口、分块），
   单纯的 SIMD 重排在无损约束下已到瓶颈

### 测量可信度说明（重要）

以上数据是在 **145 单线程、`taskset -c 0`、合成输入 `(i*7+13)%256`** 条件下测得的：

- **相对比较可靠**（同一条件交替测量，多次运行差异 1–3%，输出逐字节校验，非目标阶段作为自检）
- **绝对数字不可跨机比较**
- **未覆盖**：真实图片输入、Python 调用开销、多线程、端到端模型推理延迟
- 环境中曾出现单次 55% 的异常抖动（v1 在 321×481 上 1.55 vs 2.415 ms），已用多轮平均规避，
  但真机噪声仍需关注

---

## 8. 复现

```bash
cd /home/qch/clamp_opt

# 各版本分阶段直接测量（v1 / v2 / v4 / v5）
taskset -c 0 python3 clamp_neon_opt_stage_all.py \
  ./libpreprocess_probe.so ./libpreprocess_v2.so \
  ./libpreprocess_probe_v4.so ./libpreprocess_probe_v5.so

# clamp 成本剥离（full / cast / round / clamp 四种模式）
taskset -c 0 python3 clamp_neon_opt_clampcost.py ./libpreprocess_clampcost.so

# 端到端 + 逐字节校验
taskset -c 0 python3 clamp_neon_opt_ab5.py \
  ./libpreprocess.so ./libpreprocess_v4.so ./libpreprocess_v5.so
```

文件清单（均为新建，原仓库未改动）：

| 文件 | 说明 |
|---|---|
| `clamp_neon_opt_v2.cpp` | vertical 向量化（无损） |
| `clamp_neon_opt_v5.cpp` | v2 + 横向按像素并行（无损） |
| `clamp_neon_opt_probe*.cpp` | 各版本分阶段计时探针 |
| `clamp_neon_opt_clampcost.cpp` | clamp 成本剥离实验 |
| `clamp_neon_opt_*.py` | 测量脚本（仅标准库 + ctypes） |
