# MetaX C500 硬件规格与实测峰值

## 结论

- 加速卡为单卡 MetaX C500（PCIe 形态）：64 GB HBM2e、104 个 SM、L2 8 MB、350 W、PCIe Gen5 x16。
- 实测 BF16/FP16 GEMM 峰值 **229 TFLOPS**（16384³，已饱和），为 PCIe 版标称 240 TFLOPS 的 95.5%；FP32 矩阵 **29.8 TFLOPS**，基本等于标称 30 TFLOPS。
- HBM 实测：copy **1.40 TB/s**、triad **1.51 TB/s**、只读 reduce **1.52 TB/s**。公开资料对这块卡的带宽口径分歧极大（0.86 / 1.2 / 1.8 / 2.0 / 3.35 TB/s 都有），建议以实测为准。
- 空闲状态：XCORE 428 MHz、MC 1800 MHz、整卡 41 W（上限 350 W）。

## 主机

| 项 | 值 |
|---|---|
| CPU | Kunpeng 920 7282C，2 socket × 80 核，320 线程 |
| NUMA | 4 个 node（每 node 80 个 CPU） |
| 内存 | 565 GiB |
| 加速卡 | 8 × MetaX C500（本报告为单卡实测） |
| 操作系统 | openEuler 24.03 LTS-SP4，aarch64 |
| 内核 | 6.6.0 |
| 驱动 / 管理工具 | metax-linux 3.8.23 / mx-smi 2.3.1 |
| 固件 | BIOS 1.33.4.0 |
| 软件栈 | torch 2.8.0+metax3.7.0.7（CUDA 11.6 接口） |

`mx-smi --show-hwinfo`：Model Name `MetaX C500`、Chip Name `MXC500`、Memory Type `HBM2e`、Memory Capacity `64GB`。torch 上报 `total_memory=65,120 MB`（约 63.6 GiB）、`multi_processor_count=104`、`L2_cache_size=8 MB`。

## 标称与实测

| 项目 | 标称（PCIe 版） | 实测 |
|---|---|---|
| HBM 容量 | 64 GB HBM2e | 65,120 MB（torch 可见） |
| HBM 带宽 | 公开口径 0.86–3.35 TB/s，优化指南按 2.0 TB/s 讨论 | copy 1,398.6 GB/s；triad 1,510.9 GB/s；reduce 1,523.4 GB/s |
| FP16 / BF16 | 240 TFLOPS | bf16 229.1 TFLOPS；fp16 229.4 TFLOPS（16384³） |
| FP32 | 15 TFLOPS 矢量 / 30 TFLOPS 矩阵 | 29.8 TFLOPS（8192³） |
| TF32 | 120 TFLOPS | 未测 |
| INT8 | 480 TOPS | 未测 |
| SM 数 / L2 | 104 / 8 MB | 104 / 8 MB |
| 功耗 / 接口 | 350 W / PCIe Gen5 x16 | 空闲 41 W；pcie 32 GT/s x16 |
| 工艺 / 架构 | 7 nm / XCORE 1.0 | — |

带宽一项差异说明：优化指南中的 2.0 TB/s 应视为理论口径，实测持续带宽约为它的 75%；公开资料里 856 GB/s 的“实测有效读带宽”低于本次结果，3.35 / 18 TB/s 则明显超出单卡范围，引用时需注明口径。

GEMM 随规模的收敛情况：

| 规模 | bf16 | fp16 |
|---|---|---|
| 4096³ | 194.2 TFLOPS | 160.5 TFLOPS |
| 8192³ | 226.0 TFLOPS | 219.6 TFLOPS |
| 16384³ | 229.1 TFLOPS | 229.4 TFLOPS |

8192³ 起两种精度都已饱和；4096³ 的 fp16 偏低（160.5 TFLOPS），该尺寸不足以打满算力，不代表峰值。

## 实测方法

torch 2.8.0+metax3.7.0.7，单卡，预热后用 CUDA event 计时：

- 带宽：2 个 1 GiB bf16 张量。`copy_` 计 2 GiB 流量（1 读 1 写）；`add(x, y, out=z)` 计 3 GiB；`sum()` 计 1 GiB 读。
- 算力：bf16/fp16 取 4096³、8192³、16384³，FP32 取 8192³；`TFLOPS = 2·n³ / t`。
- 空闲频率与功耗来自 `mx-smi --show-clock`、`--show-board-power`、`--show-pcie`。

## 来源

- MetaX C500 优化指南（mcoplib，含 2.0 TB/s 口径与 SM/L2 信息）：<https://github.com/MetaX-MACA/mcoplib/blob/main/Skills/optimized-cuda-kernels/references/c500-optimization-guide.md>
- MetaX C500 规格汇总（flopper.io）：<https://flopper.io/gpu/metax-c500>
- 曦云 C500 产品参数：<https://hirobotmap.com/landing/metax/products/895/>
