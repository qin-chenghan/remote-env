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
| `MOCK_TP_CPUS` | 按 rank 绑核，如 `8,10,12,14`；每个 worker 及其全部线程都落到指定核 |
| `MOCK_TP_CPUS_DEFER=1` | 延迟到 capture 结束后再绑核，启动期的 JIT 编译用满 CPU 范围（bench 脚本默认即 1） |
| `MOCK_STACK_DUMP=1` | 注册 `SIGUSR2` → 打印所有线程的 Python 栈到 server.log（两个 bench 脚本默认已开） |
| `MOCK_THREADS` | worker 内 torch 线程数，默认 1 |

以上取值都会写进每轮的 `config.txt`（`mock_env=` 行）。卡住时：
`kill -USR2 $(pgrep -f 'VLLM::Worker')`，栈会落在该轮的 `logs/server.log`。

`MOCK_STACK_DUMP` 和 `MOCK_TP_CPUS_DEFER` 在 bench 脚本里默认取 1，**测试人员的启动命令不用改**；
需要旧行为时显式设 `0`。

## 启动停滞保护（bench 脚本）

| 变量 | 默认 | 作用 |
|---|---|---|
| `STALL_DUMP_SECONDS` | 300 | `Capturing CUDA graphs` 进度停滞这么久就自动给 worker 发 SIGUSR2；`0` 关闭。仅在 `MOCK_STACK_DUMP=1` 时生效（否则会杀进程） |
| `STALL_ABORT_SECONDS` | 1800 | 停滞这么久无任何进展就放弃本轮，避免白等到超时；`0` 关闭 |
| `SERVER_WAIT_TIMEOUT` | 0 | 启动总时长上限，`0` 不限 |

服务进程退出或停滞放弃时，脚本会把 `server.log` 最后 40 行直接打到 stdout（`stall_guard=` 行记录当前取值）。
