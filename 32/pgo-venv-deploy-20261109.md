# 32：/opt/corex311-cpython-vllm 部署记录（2026-11-09）

> 状态：已完成并验证（包 PARITY PASS + 源码树逐字节一致）。
> 判据：**同机自对齐** —— 本机 `corex311-cpython-vllm` 与 `corex311` 的差异
> 应只来自 PGO 开关；32 与 184 之间的差异不作要求。

## 1. 目标

在容器 `corex5-py311`（32）中新建 `/opt/corex311-cpython-vllm`：

- 解释器：`/opt/cpython-vllm/v1/bin/python3.11`（3.11.6，`--enable-optimizations --with-lto`）
- 包集合与源码：与 32 的 `/opt/corex311` 完全一致
- `/opt/corex311` 全程只读，未改动

目的：PGO 与否由“选哪个 venv”决定，与 `cpython-vllm-rebase` 的状态切换解耦。

## 2. 32 的环境事实（2026-11-09 实测）

| 项 | 值 |
|---|---|
| bundle | `/home/huawei_ts_program/corex5_py311_setup_20261029/assets/corex5-py311-20261009`（14 vendor wheel + installer + SHA256SUMS 完整） |
| PGO 运行时 | `/opt/cpython-vllm/v1`，3.11.6，CONFIG_ARGS 含 `--enable-optimizations --with-lto`，ensurepip 完整 |
| 非 PGO 解释器 | `/opt/python-3.11.6/bin/python3.11`（3.11.6） |
| 网络 | 容器**直连阿里云镜像可用**（HTTP 200），无需代理 |
| pip 源 | 容器内 `/root/.pip/pip.conf` → `mirrors.aliyun.com`，`trusted-host` 已配 |
| PIP_CONSTRAINT | `/opt/pip/constraints.txt`（`numpy<2`、`setuptools<82`） |
| 磁盘 | `/opt` 可用 48G（99% 已用），构建后余 44G |
| corex311 状态 | PGO（`base_prefix=/opt/cpython-vllm/v1`）；源码为 pristine（campaign 结束后停在 arm A）；仅此一个 venv |

### 32 的 corex311 包构成（183）

```
183 = requirements-py311.txt 的 166 个普通依赖
     + 14 个 vendor 包（torch/triton/vllm/ixformer/apache-tvm-ffi
       + cupy/cupy-cuda11x/cupy-cuda12x/flash-attn/pynvml/ray/torchaudio/torchvision/torchdebug）
     + cinderx 2026.10.29.2406
     + hotspot-opt 0.5.3
     + torch-module-attr-fastpath 0.1.0.dev2
```

注意：这与 184 的 172 不同（184 只装了 5 个 vendor 包）；32 按自己的现状对齐。

## 3. 执行步骤（已实际执行，2026-11-09 11:54–12:03）

### 3.1 create + 安装（官方 installer）

```bash
CON=corex5-py311
B=/home/huawei_ts_program/corex5_py311_setup_20261029/assets/corex5-py311-20261009
V=/opt/corex311-cpython-vllm
PY=/opt/cpython-vllm/v1/bin/python3.11

docker exec -e PYTHONPATH= -e PYTHONHOME= -e PIP_DISABLE_PIP_VERSION_CHECK=1 -e PIP_NO_CACHE_DIR=1 \
  "$CON" bash "$B/install_corex311.sh" "$PY" "$V"
```

脚本行为：校验 bundle `SHA256SUMS.txt` → 用 PGO 解释器 `-m venv` →
解算 `requirements-vendor-py311.txt`（14）+ `requirements-py311.txt`（166，含 pip==25.3）→
`pip check` + CPU 冒烟，证据写入新 venv 的 `corex311-cpu-verification.json`。

本次结果：`passed: true`，install rc=0。

### 3.2 装三个额外包

```bash
CX=/home/z30059427/cinderx_attr_v24_20261031_3482ac4e/cinderx-2026.10.29.2406-cp311-cp311-linux_aarch64.whl
HS=/home/qch/corex-opt/dist/hotspot_opt-0.5.3-py3-none-any.whl
TF=/home/z30059427/wheelhouse/torch_module_attr_fastpath-0.1.0.dev2-cp311-cp311-linux_aarch64.whl

docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -m pip install \
  --no-index --no-deps "$CX" "$HS" "$TF"
```

sha256（安装时记录）：

| 包 | sha256 |
|---|---|
| cinderx | `89a6e13a851e97203e5559a21038da11f7607ba60ec158a6c182fd2dffb8de22` |
| hotspot-opt | `87244f7e9fb80da0467152bc6b82c95e0174a1514fd1ff9e052044381b358972` |
| torch fastpath | `9eb6ca36702600d85b754f21e4b812394ead6c09c17dcba1cd007776a84f573b` |

### 3.3 源码级对齐（两个孤儿 .so）

corex311 的 `vllm/` 里残留两个旧 r3 卸载后的原生扩展（pristine 代码不 import，
全树无引用）。为达到文件级一致，原样拷入新 venv：

```bash
S=/opt/corex311/lib/python3.11/site-packages
N=/opt/corex311-cpython-vllm/lib/python3.11/site-packages
docker exec "$CON" sh -c "cp -n $S/vllm/_host_opt_native.abi3.so $N/vllm/; \
  cp -n $S/vllm/_host_opt_meta_native.cpython-311-aarch64-linux-gnu.so $N/vllm/"
```

拷贝后 sha256：

- `_host_opt_native.abi3.so` = `6f8774f8c9e6839a3a1de15a763845511f200cb485f55ef10009475e30db8056`
- `_host_opt_meta_native.cpython-311-aarch64-linux-gnu.so` = `7c8686a72759d2e4f75e8157b819039fcdcf69c1b5eba5948e0d956859af1715`

### 3.4 pillow / cryptography 二进制对齐

两侧版本相同（pillow 12.1.1、cryptography 50.0.2），但从镜像解析到的 wheel 构建
不同（`pillow.libs` 库文件名哈希不同、PIL 8 个 `.so` 与 cryptography
`_rust.abi3.so` 内容不同）。

处理：用 corex311 的 `PIL/`、`pillow.libs/`、`cryptography/` 及对应 dist-info
覆盖新 venv（先删后拷）：

```bash
docker exec "$CON" sh -c '
S=/opt/corex311/lib/python3.11/site-packages
N=/opt/corex311-cpython-vllm/lib/python3.11/site-packages
for d in PIL pillow.libs cryptography; do rm -rf "$N/$d"; cp -a "$S/$d" "$N/"; done
for di in pillow cryptography; do rm -rf "$N"/$di-*.dist-info; cp -a "$S"/$di-*.dist-info "$N/"; done
'
```

覆盖后 import 冒烟通过（PIL 12.1.1 / cryptography 50.0.2）。

## 4. 验收结果

| 检查 | 结果 |
|---|---|
| `pip check` | No broken requirements found |
| 包元数据（importlib.metadata，PEP 503 归一化） | **base=183，new=183，only_base=0，only_new=0，mismatch=0 → PARITY PASS** |
| vllm 源码树 `diff -rq`（排除 `__pycache__`） | **空，逐字节一致** |
| 顶层 site-packages diff（排除 dist-info/pycache） | 仅剩 corex311 的两个残留：`.host-opt-pr-build/`、`VERIFICATION.json`（非包、不被 import） |
| import 冒烟 | PIL / cryptography / vllm / torch 全部 OK；cinderx 在 PGO 下 import OK |
| 解释器 | `prefix=/opt/corex311-cpython-vllm`，`base_prefix=/opt/cpython-vllm/v1`，PGO=True |
| 磁盘 | 两个 venv 各 4.1G，`/opt` 余 44G |

## 5. 已知边界

1. **cinderx** 通过 `cinderx.pth` 在解释器启动时自动 `import _cinderx_auto`；
   本次只做了 import 冒烟，未做长时间稳定性/端到端性能验证。官方 bundle
   README 明确要求 cinderx 与自定义解释器的兼容性单独验收——如果后续出现
   启动异常或崩溃，先把 `cinderx.pth` 挪开（包保留、不自动加载）再排查。
2. **corex311 仍是 PGO**，脚本/服务若走默认 `PREFIX=/opt/corex311`，用的还是
   共享 venv；做 PGO A/B 前需用 `/home/qch/scripts/pgo-doctor.py off` 切到非 PGO
   （或让脚本显式指向两个 venv）。
3. 32 的 bench 脚本尚未做 184 那样的“静态 venv + 断言”改造。
4. `.host-opt-pr-build/`、`VERIFICATION.json` 是 corex311 的历史残留，未复制到
   新 venv；如需逐字节完全一致可另行拷贝。

## 6. 回滚

新 venv 是本次唯一新建的目录，直接删除即可（corex311 未动）：

```bash
docker exec corex5-py311 rm -rf /opt/corex311-cpython-vllm
```

## 7. 复验命令（任何时候可跑）

```bash
# 解释器/PGO
docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 \
  /opt/corex311-cpython-vllm/bin/python -c \
  'import sys,sysconfig; print(sys.prefix); print(sys.base_prefix); print("--prefix=/opt/cpython-vllm/v1" in (sysconfig.get_config_var("CONFIG_ARGS") or ""))'

# pip check
docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 \
  /opt/corex311-cpython-vllm/bin/python -m pip check

# 源码树
docker exec corex5-py311 sh -c \
  "diff -rq --exclude='__pycache__' /opt/corex311/lib/python3.11/site-packages/vllm /opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm"

# 包集合（与 184 文档同款 importlib.metadata 对比脚本，两侧均为 183）
```

## 8. 与 184 的差异（供对照，不要求一致）

| 项 | 184 | 32 |
|---|---|---|
| corex311 包数 | 172（5 vendor + fastpath） | 183（14 vendor + cinderx + hotspot + fastpath） |
| 网络 | 需代理（`141.1.61.31:3129`），容器无 DNS | **直连**，无需代理 |
| 源码补丁 | corex311 有 host fastpath 变体（同事更新中，新 venv 尚未对齐） | corex311 pristine，新 venv 已逐字节一致 |
| 旧 venv 隔离 | `/opt/_trash_20261109-090312` | 无（新建，无可隔离的旧 venv） |
