# Qwen3-0.6B 1024/1024 延迟与吞吐（MetaX C500）

## 结论

- 单卡 MetaX C500（64 GB）上，Qwen3-0.6B bf16、TP=1、`max_model_len=4096`，100 条 1024/1024 请求：
  - 并发 8：输出 **1,565.8 tok/s**，TTFT 中位数 92.1 ms，TPOT 中位数 4.86 ms；
  - 并发 100：输出 **5,355.6 tok/s**（3.42×），TTFT 中位数 1,012.3 ms，TPOT 中位数 17.48 ms。
- 并发 100 时服务端 `Running: 100 / Waiting: 0`，GPU KV cache 使用率仅 **32.1%**，并发上限还没到；但本次 `num_prompts=100`，bench 的并发不可能超过 100，要测更高并发必须增加请求数。
- 该环境没有 litehost，指标全部由 `vllm bench serve` 客户端侧统计，不含 H/G 拆分。

## 环境

| 项 | 值 |
|---|---|
| 加速卡 | MetaX C500，64 GB HBM2e，单卡 |
| 模型 | Qwen3-0.6B，bf16 |
| vLLM | 0.21.0（MetaX 版），torch 2.8.0+metax3.7.0.7 |
| 调度 | chunked prefill 开，prefix caching 关，async scheduling 开，compilation config 默认 |
| 显存 | `gpu_memory_utilization=0.9`，`max_model_len=4096` |

## 结果

| 并发 | 耗时 s | req/s | 输出 tok/s | 总 tok/s | TTFT mean/median/p99 ms | TPOT mean/median/p99 ms | ITL mean/median/p99 ms |
|---|---|---|---|---|---|---|---|
| 8 | 65.40 | 1.53 | 1,565.8 | 3,131.6 | 95.8 / 92.1 / 170.2 | 4.84 / 4.86 / 4.90 | 4.84 / 4.80 / 5.16 |
| 100 | 19.12 | 5.23 | 5,355.6 | 10,711.1 | 1,036.2 / 1,012.3 / 1,911.8 | 17.42 / 17.48 / 17.83 | 17.42 / 17.10 / 35.95 |

两组均 100/100 成功、0 失败。并发 100 的峰值输出吞吐 7,391 tok/s。

## 备注

- 并发 100 时 TPOT 从 4.84 ms 升到 17.4 ms；ITL 的 p99（36 ms）明显高于 TPOT 的 p99（17.8 ms），说明高并发下存在少量解码步抖动。本次没有同机 128/128 数据，暂不做跨 case 推断。
- 服务首次启动约 255 s（含图编译），基准本身两组合计约 85 s。
- 该数据来自 MetaX 的 vLLM 0.21.0，与 Iluvatar 侧的 0.23.0 不是同一版本，跨卡对比时需注明。

## 复现

```bash
# 容器内，单卡
python3 -m vllm.entrypoints.openai.api_server \
  --host 127.0.0.1 --port 8000 --model /model --trust-remote-code --dtype auto \
  --max-model-len 4096 --tensor-parallel-size 1 --gpu-memory-utilization 0.9 \
  --async-scheduling --enable-chunked-prefill --no-enable-prefix-caching

python3 -m vllm.entrypoints.cli.main bench serve --backend vllm \
  --num_prompts 100 --num-warmups 16 --max-concurrency 100 \
  --dataset_name random --random_input_len 1024 --random_output_len 1024 \
  --host 127.0.0.1 --port 8000 --model /model --trust-remote-code \
  --ignore_eos --top_p 1 --top_k -1 --temperature 0 --seed 42
```
