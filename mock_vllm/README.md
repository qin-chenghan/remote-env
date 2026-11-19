# mock_vllm

在**没有 GPU** 的机器上跑 vLLM 的 host 侧代码路径：保留 vLLM 的 Python 调度/前处理/采样/模型层循环，
只把设备下发（ixformer kernel、通信 pybind、CUDA runtime、图回放）替换成 C 级空实现。
用来在 CPU 上对比 host 侧优化，不占卡、不出 kernel。

设计口径、逐项处置表和帧对齐结果见 blue-dev 仓的 `docs/mock-vllm-design.md`。

## 权威版本

**唯一权威源是本仓库的 `mock_vllm/`**，各服务器一律部署这一份：

```bash
cd <remote-env 克隆> && git pull      # 更新
```

- 服务器上的路径 `/home/qch/mock_vllm` 建议软链到克隆内的 `mock_vllm`（145 与 32 都是这样）。
  不要在服务器副本上直接改代码，否则会和本仓分叉。
- 启动日志里的 `id=xxxxxxxxxx` 是 `mock_gpu/*.py` 的内容哈希，**H 数据只与同一 id 的结果可比**；
  结果目录（`config.txt` 或 `logs/server.log`）里应能看到该 id。
- 冻结基线时记录当时的 commit（`git rev-parse HEAD`）与 id。

## 兼容性

- Linux x86_64，Python 3.11，装有 Iluvatar 版 vLLM 和 torch 的 venv（开发机上是 `/opt/corex311`）。
- 按**名字**打补丁（vLLM/torch/ixformer 内部函数、文件行号），**绑定具体版本**：换 vLLM 或 torch
  版本后要先跑一遍 `bash` 冒烟，确认 `[mock_gpu] activated` / `[mock_gpu] worker patched` 都出现。
- 只在没有可见设备时自动生效：`/dev/iluvatar0` 不存在，或 `CUDA_VISIBLE_DEVICES=-1`。
  在有卡机器上不加这两个条件时 mock 不会启动，可以安全放置。

## 部署

```bash
# 1. 放到任意目录，例如 /home/qch/mock_vllm
cp -R mock_vllm /home/qch/mock_vllm
cd /home/qch/mock_vllm

# 2. 编 litehost 用的符号垫片（只在用 litehost 量 H 时需要）
gcc -shared -fPIC -o mock_ix.so mock_ix.c
```

激活靠 `PYTHONPATH`：Python 启动时会自动 import 路径上的 `sitecustomize.py`，由它 import
`mock_gpu.autoload`。所以只要：

```bash
PYTHONPATH=/home/qch/mock_vllm /opt/corex311/bin/python -m vllm.entrypoints.openai.api_server ...
```

启动日志出现 `[mock_gpu] activated: no Iluvatar device visible` 和每个 worker 的
`[mock_gpu] worker patched` 即生效；去掉 `PYTHONPATH` 即完全卸载，不改 vllm 源码、不装包。

> `sitecustomize.py` 是兜底入口；如果 venv 里已经有别的 `sitecustomize`，改用 .pth 注入：
> `printf '%s\nimport mock_gpu.autoload\n' "$PWD" > $VENV/lib/python3.11/site-packages/zz_mock_gpu.pth`
> （删除该文件即卸载）。

### 配套 bench 脚本

`vllmBench_lite_base_timeline.sh` 在无 `/dev/iluvatar0` 时默认 `MOCK_DIR=/home/qch/mock_vllm`
（端口 8948、CPU 0-63）。部署到别处时显式传路径：

```bash
MOCK_DIR=/path/to/mock_vllm TEST_ID=mock_xxx bash vllmBench_lite_base_timeline.sh
```

`cases9.txt` 是 9 case 矩阵的 `CASES_FILE` 示例。

## 开关

| 环境变量 | 默认 | 作用 |
|---|---|---|
| `MOCK_THREADS` | `1` | torch intra-op 线程数，对齐 GPU worker 的单线程设置 |
| `MOCK_PREFILL` | `1` | `0` = 用假模型（不做真实层循环），只测框架路径 |
| `MOCK_EAGER` | `0` | `1` = 关掉 cudagraph，全 eager |
| `MOCK_SAMPLE_CAST` | `1` | `0` = 不替采样器的 fp32 大张量转换（对照组） |
| `MOCK_IX_LIB` | `<dir>/mock_ix.so` | 符号垫片路径 |
| `LIGHTHOST_LIB` / `LIGHTHOST_SESSION` | 由 litehost 设置 | 存在时同步/图下发走 `mock_ix.so`，H/G 才有效 |

## 已验证的对齐程度（Qwen3-32B-W8A8，TP=4，128/128）

`execute_model` 窗口内的 python 帧名逐项对齐（rank0，中段 step）：

| | base 帧名/调用 | mock 帧名/调用 | 共同帧名 |
|---|---|---|---|
| prefill | 1273 / 30584 | 1202 / 30282 | 1196 |
| decode | 249 / 727 | 207 / 573 | 204 |

mock 独有帧只有 3 类：设备叶子替换点 `_noop`（prefill 1091 次，与 base 设备叶子一一对应）、
`linear_ex` 的 `<lambda>`、采样器 fp32 转换的 `to`；prefill 另有 CPU inductor 的 mask kernel 3 帧。
base 独有的都是设备叶子、CUDA runtime/Event、`torch.cuda` 懒初始化链、triton/inductor 启动机制。

**已知偏差（A/B 时按常量看待）**

- 设备提交成本整体不在 mock 里：base 每步的 triton JIT 启动链（slot-mapping 内核）约 100–200 µs
  （profile 口径），prefill 的 1091 次设备叶子调用合计约 22 ms；mock 对应位置是空替身（µs 级）。
  因此 mock 的 H 天然远低于 base，**只能比相对差值**；减少下发次数/启动开销类优化在 mock 上看不出来。
- prefill 的 causal-mask kernel 在 mock 里编成 CPU kernel 跑（约 13 µs/step，结果无人读取）。
- trace 时长不能直接比：base 的 `execute_model` 里包含 device 等待，profiler 对 3 万帧/步也有放大。

## 目录

```
mock_vllm/
├── mock_gpu/
│   ├── autoload.py      # 入口：无卡时打补丁
│   ├── worker_patch.py  # 假 Stream/Event/sync、设备叶子替身、加载窗口替身、帧名对齐
│   ├── runner.py        # MockGPUModelRunner：CPU 上构造并加载真实模型、采样/设备替换
│   ├── fake_graph.py    # 假 CUDAGraph（replay 帧名对齐 torch/cuda/graphs.py:141）
│   ├── dispatch.py      # 阶段计数与审计
│   ├── counters.py      # 计数器
│   └── comm.py          # 单 rank 通信桩
├── sitecustomize.py     # PYTHONPATH 自动激活
├── mock_ix.c            # litehost 符号垫片源码（同步/图下发空实现）
├── mock_ixrt.c          # 可选：IXRT 空实现源码，mock_gpu 不引用
└── cases9.txt           # 9 case 矩阵示例
```
