#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  # 本轮只读：不安装、不改任何文件。

  echo "== 1. transfer 目录 / wheel 是否已上传 =="
  ls -l /home/qch/transfer 2>/dev/null | tail -20
  WHL=/home/qch/transfer/hotspot_opt-0.5.3-py3-none-any.whl
  if [ -f "$WHL" ]; then
    sha256sum "$WHL"
    echo "expected: 87244f7e9fb80da0467152bc6b82c95e0174a1514fd1ff9e052044381b358972"
  else
    echo "wheel not uploaded yet: $WHL"
  fi

  echo "== 2. torch fastpath 安装记录 =="
  docker exec corex5-py311 /opt/corex311/bin/pip show torch-module-attr-fastpath 2>&1 | head -6

  echo "== 3. torch fastpath 状态（venv 干净 sys.path）=="
  docker exec -e PYTHONPATH= -e TORCH_MODULE_ATTR_FASTPATH=slot_native corex5-py311 \
    /opt/corex311/bin/python3 -c \
    "import torch, torch_module_attr_fastpath as m; print('torch:', torch.__version__, torch.__file__); print(m.status())"

  echo "== 4. 容器默认 PYTHONPATH 对照（预期加载 3.12 的 torch 并失败）=="
  docker exec -e TORCH_MODULE_ATTR_FASTPATH=slot_native corex5-py311 \
    /opt/corex311/bin/python3 -c \
    "import torch; print(torch.__file__)" 2>&1 | tail -4

  echo "== 5. 容器默认 env =="
  docker exec corex5-py311 sh -c \
    'echo PYTHONPATH=${PYTHONPATH:-<empty>}; echo LD_PRELOAD=${LD_PRELOAD:-<empty>}'

  echo "== 6. 当前 vLLM 进程环境 =="
  for p in $(pgrep -f vllm.entrypoints.openai.api_server 2>/dev/null); do
    echo "-- PID $p --"
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null \
      | grep -E 'PYTHONPATH|TORCH_MODULE_ATTR_FASTPATH|VLLM_HOST_FASTPATH|HOTSPOT_OPT' || true
  done

  echo "== 7. 压测/服务进程 =="
  pgrep -af 'vllmBench_lite_opt.sh|bench_driver.py' 2>/dev/null | head -10 || true

  echo "== 8. rebase / PGO 状态 =="
  docker exec corex5-py311 sh -c \
    'ls -la /root/.local/state/cpython-vllm-rebase 2>/dev/null | head -8 || echo "no rebase state"'
  docker exec corex5-py311 sh -c \
    '/opt/corex311/bin/python3 -c "import sysconfig; print(sysconfig.get_config_var(\"CONFIG_ARGS\"))"'

  echo "== 9. /opt 可写性、磁盘、已有安装 =="
  docker exec corex5-py311 sh -c \
    'test -w /opt && echo "/opt writable" || echo "/opt NOT writable"; df -h /opt /home | tail -3'
  docker exec corex5-py311 sh -c \
    'ls -d /opt/hotspot_site 2>/dev/null || echo "no /opt/hotspot_site"; /opt/corex311/bin/pip show hotspot-opt 2>/dev/null | head -3 || echo "hotspot-opt not in venv"'

  echo "== 10. vLLM API 兼容性（tokens patch 依赖）=="
  docker exec -e PYTHONPATH= corex5-py311 /opt/corex311/bin/python3 -c '
import inspect
import vllm
from vllm.model_executor.layers.logits_processor import LogitsProcessor
from vllm.v1.worker.gpu_model_runner import GPUModelRunner

print("vllm", vllm.__version__)
print("has_get_top_tokens", hasattr(LogitsProcessor, "get_top_tokens"))
print("forward_params", list(inspect.signature(LogitsProcessor.forward).parameters))
print("_sample_calls_sampler", "self.sampler(" in inspect.getsource(GPUModelRunner._sample))
print("_sample_file", GPUModelRunner._sample.__code__.co_filename)
'

  echo "== 11. 启动脚本的 PYTHONPATH / 环境注入位置 =="
  for f in /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh /home/qch/scripts/vllmBench_lite_on.sh; do
    if [ -f "$f" ]; then
      echo "-- $f --"
      grep -n 'PYTHONPATH\|HOST_FASTPATH\|TORCH_MODULE_ATTR\|export ' "$f" | head -25
    fi
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
