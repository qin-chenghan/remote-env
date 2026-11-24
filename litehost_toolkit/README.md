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
| `MOCK_TP_CPUS_DEFER=1` | 延迟到 capture 结束后再绑核，启动期的 JIT 编译用满 CPU 范围 |
| `MOCK_STACK_DUMP=1` | 注册 `SIGUSR2` → 打印所有线程的 Python 栈到 server.log |
| `MOCK_THREADS` | worker 内 torch 线程数，默认 1 |

以上取值都会写进每轮的 `config.txt`（`mock_env=` 行）。卡住时：
`kill -USR2 $(pgrep -f 'VLLM::Worker')`，栈会落在该轮的 `logs/server.log`。
