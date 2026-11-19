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
