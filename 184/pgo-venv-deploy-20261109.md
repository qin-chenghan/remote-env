# 184：/opt/corex311-cpython-vllm 部署记录（2026-11-09）

> 状态：已完成并验证（PARITY PASS）。本文件是可复现的部署档案。
> 证据日志：`184/tmp/20261109-090309.log`（安装）、`20261109-091656.log`（trim + parity）。

## 1. 目标与背景

- `cpython-vllm-rebase` 的状态切换脆弱：容器重启导致 `st_dev` 变化报
  `VENV_DIRECTORY_REPLACED`；装包导致 `PACKAGE_METADATA_CHANGED`；切换失败需
  `pgo-doctor` 介入。
- 改为静态方案：**PGO 与否 = 选哪个 venv**，与 rebase 工具无关。
- 本次在容器 `corex5-py311` 中新建 `/opt/corex311-cpython-vllm`：
  - 解释器：`/opt/cpython-vllm/v1/bin/python3.11`（3.11.6，`--enable-optimizations --with-lto`）
  - 包集合：与 `/opt/corex311` 严格一致（172 个）
  - `/opt/corex311` 未改动

## 2. 环境事实（实测）

| 项 | 值 |
|---|---|
| 容器 network mode | `host` |
| 厂商 bundle | `/home/z30059427/corex5-py311-20261009` |
| bundle 内容 | 14 个 vendor wheel + `requirements-vendor-py311.txt` + `requirements-py311.txt`(166 pin) + `install_corex311.sh` + `verify_corex311.py` + `SHA256SUMS.txt` |
| 普通依赖 | **不在 bundle 内**（`vendor/` 之外无 wheels），需联网 |
| 容器 DNS | 不可用；必须走代理 |
| 代理 | `http://141.1.61.31:3129`（`/home/qch/env/set_proxy.sh` 设置小写变量） |
| 代理传参 | `docker exec` **不继承宿主环境**，必须显式 `-e http_proxy=... -e https_proxy=...` |
| pip 源 | `/root/.pip/pip.conf` → `mirrors.aliyun.com`，`trusted-host` 已配 |
| 注意 | 裸 `urllib` 走代理会因代理自签证书报 SSL 失败；pip 因 trusted-host 可正常下载 |
| PIP_CONSTRAINT | `/opt/pip/constraints.txt`：`numpy<2`、`setuptools<82`（与 requirements 无冲突） |

### base venv 的构成（重建依据）

```
172 = requirements-py311.txt 的 166 个普通依赖
     + 5 个 vendor 包：torch / triton / vllm / ixformer / apache-tvm-ffi
     + torch_module_attr_fastpath 0.1.0.dev2（手工装）
```

vendor 清单里的另外 **9 个包 base 没有**，重建后已卸掉：
`cupy`、`cupy-cuda11x`、`cupy-cuda12x`、`flash-attn`、`pynvml`、`ray`、
`torchaudio`、`torchvision`、`torchdebug`。

原因：这些包在 base 缺失；保留会改变 vLLM 运行时探测（ray/flash-attn/cupy），
做 A/B 时是混淆变量。

## 3. 执行步骤

### 3.1 隔离旧 venv（3.5G，无进程占用）

```bash
TS=$(date +%Y%m%d-%H%M%S)
docker exec corex5-py311 sh -c \
  "mkdir -p /opt/_trash_$TS && mv /opt/corex311-cpython-vllm /opt/_trash_$TS/corex311-cpython-vllm-old"
```

实际隔离路径：`/opt/_trash_20261109-090312/corex311-cpython-vllm-old`。

### 3.2 官方 installer 建 venv 并安装

```bash
source /home/qch/env/set_proxy.sh
docker exec \
  -e http_proxy="$http_proxy" -e https_proxy="$https_proxy" -e no_proxy="$no_proxy" \
  -e PYTHONPATH= -e PYTHONHOME= -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
  corex5-py311 bash /home/z30059427/corex5-py311-20261009/install_corex311.sh \
  /opt/cpython-vllm/v1/bin/python3.11 /opt/corex311-cpython-vllm
```

脚本行为：校验 bundle `SHA256SUMS.txt` → 用给定解释器 `-m venv` →
解算 `requirements-vendor-py311.txt` + `requirements-py311.txt` →
`pip check` + CPU 冒烟，证据写入新 venv 的
`corex311-cpu-verification.json`。

注意：脚本**拒绝已存在的 venv 目录**；失败时不会自动删除，需手动清理后重试。
`--find-links "$bundle_dir/wheels"` 指向不存在的目录，pip 容忍（README 的离线
方案需自行准备该目录）。

本次结果：`passed: true`；venv 自带 pip 25.3、setuptools 80.9.0、wheel 0.45.1
（与 base 一致，无需再升级）。

### 3.3 卸掉 base 没有的 9 个 vendor 包

```bash
docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 \
  /opt/corex311-cpython-vllm/bin/python -m pip uninstall -y \
  cupy cupy-cuda11x cupy-cuda12x flash-attn pynvml ray \
  torchaudio torchvision torchdebug
```

### 3.4 装 torch_module_attr_fastpath 0.1.0.dev2

```bash
FW=/home/qch/transfer/torch_module_attr_fastpath-0.1.0.dev2-cp311-cp311-linux_aarch64.whl
# sha256 必须为 9eb6ca36702600d85b754f21e4b812394ead6c09c17dcba1cd007776a84f573b
docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 \
  /opt/corex311-cpython-vllm/bin/python -m pip install --no-index --no-deps "$FW"
```

该 wheel 带 `.pth` 引导；只有环境变量 `TORCH_MODULE_ATTR_FASTPATH=slot_native`
设置时才生效，默认惰性。

### 3.5 严格 parity 验收

用 `importlib.metadata` 从两个解释器各 dump「包名 → 真实版本」，名称按 PEP 503
归一化后比较（绕开 `pip freeze` 的 `@ file://` 渲染差异）：

```bash
docker exec -i -e PYTHONPATH= -e PYTHONHOME= corex5-py311 \
  /opt/corex311-cpython-vllm/bin/python - <<'PY'
import json, os, re, subprocess

norm = lambda n: re.sub(r"[-_.]+", "-", n.strip().lower())
DUMP = (
    "import importlib.metadata as m, json\n"
    "d = {}\n"
    "for dist in m.distributions():\n"
    "    try:\n"
    "        n = dist.metadata['Name']; v = dist.version\n"
    "    except Exception:\n"
    "        continue\n"
    "    if n and v: d[n] = v\n"
    "print(json.dumps(d))\n"
)

def dump(interp):
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "PYTHONHOME")}
    r = subprocess.run([interp, "-c", DUMP], capture_output=True, text=True, env=env)
    return json.loads(r.stdout.strip().splitlines()[-1])

base = {norm(k): v for k, v in dump("/opt/corex311/bin/python").items()}
new = {norm(k): v for k, v in dump("/opt/corex311-cpython-vllm/bin/python").items()}
print(f"base={len(base)} new={len(new)}")
print("only_base", sorted(set(base) - set(new)))
print("only_new ", sorted(set(new) - set(base)))
print("mismatch ", sorted(k for k in set(base) & set(new) if base[k] != new[k]))
PY
```

实际结果：

```
base datasets=172 new datasets=172
only_base=0 only_new=0 mismatch=0
PARITY PASS: 包集合与版本完全一致
```

## 4. 最终状态

| 项 | 值 |
|---|---|
| `sys.prefix` | `/opt/corex311-cpython-vllm` |
| `sys.base_prefix` | `/opt/cpython-vllm/v1` |
| `CONFIG_ARGS` | 含 `--prefix=/opt/cpython-vllm/v1`、`--enable-optimizations`、`--with-lto` |
| 包 | 172，与 base 零差异 |
| 工具链 | pip 25.3 / setuptools 80.9.0 / wheel 0.45.1 |
| `pip check` | No broken requirements found |
| 导入 | vllm 0.23.0 / torch 2.10.0 |
| 磁盘 | 新 venv 3.7G；旧 venv 隔离中；`/opt` 剩余 3.2T |
| 进程占用 | 无 |

## 5. 未包含与待办

1. **源码级补丁未装**：新 venv 是原生 vllm。base（共享 venv）当前有同事更新的
   host fastpath 变体 `b869bfb1…`（含 R3-V3 decode fastpath，`VLLM_DISABLE_DECODE_FASTPATH`
   为 kill switch）。做 PGO A/B 前，两边必须打**同一套**补丁；
   旧版 r3 交付包在 `/home/qch/transfer/host-opt-pr-validation-20261103-r3`。
2. **bench 脚本尚未改**：已准备好补丁（删除 rebase 切换；base 断言非 PGO、
   opt 默认 `PREFIX=/opt/corex311-cpython-vllm` 并检查 `host_fastpath.py` 存在），
   执行前会检查无 bench/vllm 进程，有则中止。
3. **corex311 的 PGO 状态**：目前仍是 PGO；用户计划空闲时用
   `/home/qch/scripts/pgo-doctor.py off` 切回 base。切换后 base 脚本才能跑。
4. **旧 venv 清理**：`/opt/_trash_20261109-090312` 观察一段时间后再删。
5. `tcmalloc` 是进程级 `LD_PRELOAD`，不属于 venv。

## 6. 回滚

```bash
docker exec corex5-py311 sh -c \
  'rm -rf /opt/corex311-cpython-vllm && \
   mv /opt/_trash_20261109-090312/corex311-cpython-vllm-old /opt/corex311-cpython-vllm'
```

## 7. 复验命令（任何时候可跑）

```bash
docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 \
  /opt/corex311-cpython-vllm/bin/python -c \
  'import sys,sysconfig; print(sys.prefix); print(sys.base_prefix); print(sysconfig.get_config_var("CONFIG_ARGS"))'

docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 \
  /opt/corex311-cpython-vllm/bin/python -m pip check

docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 \
  /opt/corex311-cpython-vllm/bin/python -c \
  'import vllm,torch; print(vllm.__version__, torch.__version__)'
```

## 8. 同日相关变更（追溯用）

- 2026-11-06：184 与 32 的 fastpath 8 个关键文件逐字节一致；184 上旧
  metadata 补丁残留（`vllm/.corex_metadata_patch/` + 4 个 `vllm/iluvatar/*.py`）
  已隔离到 `/opt/_trash_20261106-165313`（引用检查通过、清理前后关键文件 hash 不变）。
- ⚠️ 2026-11-09：32 的 `corex311` 正被一个 decode-host ablation campaign 按
  arm A/B 交替改写源码，哈希会随 arm 变化；**不要再拿 32 的当前哈希当基准**。
- 184 的 `corex311` 同期被同事更新为 `b869bfb1…` 变体，并在跑 opt 基准
  （`/home/s00806700/litehost_perf_opt/`）。做任何对比前先确认两侧补丁版本。

## 9. 已知坑清单

1. `docker exec` 不继承宿主 env → 代理必须显式 `-e`。
2. 容器无 DNS → 不要用直连方式测试网络；用 pip 或带代理的请求。
3. pip 能过代理是因 `trusted-host=mirrors.aliyun.com`；裸 HTTPS 会 SSL 失败。
4. installer 拒绝覆盖已存在的 venv。
5. `pip freeze` 对直接 URL 安装显示 `@ file://`，与普通 `==` 渲染不同；
   做包对比必须按真实元数据（`importlib.metadata`）比较。
6. venv 与 rebase 工具无关；不要对 venv 运行 `cpython-vllm-rebase`。
