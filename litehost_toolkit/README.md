# litehost_toolkit

litehost 的测量工具包（来自 32 的 `/home/huawei_ts_program/litehost_perf_opt`），
用于在各服务器上部署同一套 H/G 测量与 trace 采集环境。

- `liblitehost.so` + `liblitehost.build.json`：预加载库与其构建指纹（`lhctl.py` 校验 sha256）。
- `lhctl.py` / `lh_runtime.py` / `lh_common.py` / `analyze_litehost.py`：会话、rank 通信与结果分析。
- `bench_driver.py` + `vllmBench_lite_base_mock.sh`：mock 环境的 lite(H/G) 压测入口（端口 8948、CPU 0-63）。
- `vllmBench_lite_base_timeline.sh`：torch profiler 入口，出 Perfetto trace。
- `litehost.c` / `liblitehost.wrappers.cpp` / `Makefile`：库源码，可用 `make` 重新构建。
- `litehost.sha256`：部署后用于校验文件完整性（`sha256sum -c`）。

部署脚本见各服务器目录下的 `cmd.sh`，它把本目录同步到
`/home/huawei_ts_program/litehost_perf_opt` 并执行校验。

## mock 相关环境变量

| 变量 | 作用 |
|---|---|
| `MOCK_TP_CPUS` | 按 rank 绑核，如 `8,10,12,14`；**服务就绪后**由 bench 脚本用 `taskset -apc` 施加 |
| `MOCK_STACK_DUMP=1` | 注册 `SIGUSR2` → 打印所有线程的 Python 栈到 server.log（两个 bench 脚本默认已开） |
| `MOCK_THREADS` | worker 内 torch 线程数，默认 1 |

以上取值都会写进每轮的 `config.txt`（`mock_env=` 行；`MOCK_TP_CPUS` 带 `@runtime` 后缀）。
卡住时：`kill -USR2 $(pgrep -f 'VLLM::Worker')`，栈会落在该轮的 `logs/server.log`。

两个 bench 脚本对 `MOCK_TP_CPUS` 的处理是：**启动阶段不绑**——服务进程的
`MOCK_TP_CPUS` 被显式置空（mock 自身的 `MOCK_TP_CPUS_DEFER` 路径也一并关掉），
导入、权重加载、capture 都在完整 CPU 范围上跑；`/health` 就绪之后才逐个 rank
用 `taskset -apc <cpu> <pid>`（作用于该进程全部线程）绑上去，随后回读
`Cpus_allowed_list` 审计。rank→pid 取自 `control/rank<N>.ready.json`，
off 模式退回解析 `server.log`。绑核失败直接放弃本轮，不产出未绑核的数据。

脚本自身的判定（绑核、停滞保护、启动失败）除了打到终端，还追加到该轮的
`logs/harness.log`，事后可查。

## 启动停滞保护（bench 脚本）

| 变量 | 默认 | 作用 |
|---|---|---|
| `STALL_DUMP_SECONDS` | 300 | `Capturing CUDA graphs` 进度停滞这么久就自动给 worker 发 SIGUSR2；`0` 关闭。仅在 `MOCK_STACK_DUMP=1` 时生效（否则会杀进程） |
| `STALL_ABORT_SECONDS` | 900 | 停滞这么久无任何进展就放弃本轮，避免白等到超时；`0` 关闭 |
| `SERVER_WAIT_TIMEOUT` | 0 | 启动总时长上限，`0` 不限 |
| `VLLM_ENGINE_READY_TIMEOUT_S` | 1800 | vLLM 等待引擎初始化 RPC（权重加载后到 capture 完成）的时间；vLLM 默认只有 600，冷缓存编译会因此被判死 |

服务进程退出或停滞放弃时，脚本会把 `server.log` 最后 40 行直接打到 stdout（`stall_guard=` 行记录当前取值）。

## 重启/迁移后的预热

虚机重启后可能落到 CPU 特性不同的宿主上。inductor 的 PCH 键（`codecache.py:_precompile_header`）
由 头文件内容 + g++ 命令行 + **预处理结果** + g++ 版本 组成，而命令行里是 `-march=native`，
所以宿主变了键就变，PCH 与内核必须按新宿主编一遍。这是正确行为，不是缓存损坏。

重启后先付款，正式测量就只剩缓存命中：

```bash
WARMUP_ONLY=1 bash vllmBench_lite_base_mock_py312.sh
```

预热沿用同一份启动参数，只启动到 `/health`（含权重加载与 graph capture）然后停掉服务，
不跑 case、不需要测量端在线；结束时打印本次新增的 PCH 与 `.so` 数量。
之后按平时的命令跑测量即可。`config.txt` 里会记 `warmup_only=1`，便于事后区分。

PCH 有宿主相关的键，内核 `.so` 却没有：同一个 `.so` 在不同宿主间会被直接复用，
执行到本机不支持的指令就把 worker 打死（表现为 capture 卡在 0/N 后
`Worker proc ... died unexpectedly`，日志里没有 Python 栈）。所以
`TORCHINDUCTOR_CACHE_DIR` 现在按 `CPU Features + g++ 版本` 的哈希分片
（`inductor_cache_py312/h-<10位哈希>`），`config.txt` 里记 `host_tag=`。
宿主没变照常复用；宿主变了自动换目录重编，预热承担这一次开销。
