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
  # 驱动已恢复：确认 8 卡 -> 启动容器 -> 验证容器设备与两个 venv 状态。

  echo "== 1. 宿主设备与 GPU 数 =="
  ls /dev/iluvatar* | wc -l
  ls -l /dev/iluvatar* | head -10
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>/dev/null | grep -c "BI-V150" || true

  echo "== 2. 启动容器 =="
  docker start corex5-py311
  echo "start rc=$?"
  docker ps --filter name=corex5-py311 --format '{{.Names}} {{.Status}}'
  sleep 3

  echo "== 3. 容器内设备/GPU =="
  docker exec corex5-py311 sh -c 'echo -n "devices: "; ls /dev/iluvatar* 2>/dev/null | wc -l; echo -n "gpus: "; ixsmi 2>/dev/null | grep -c "BI-V150" || echo ixsmi-fail'

  echo "== 4. corex311 状态 =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 /opt/corex311/bin/python -c \
    'import sys,sysconfig;print("prefix",sys.prefix);print("base_prefix",sys.base_prefix);print("pgo","--prefix=/opt/cpython-vllm/v1" in (sysconfig.get_config_var("CONFIG_ARGS") or ""))' 2>&1 | tail -3

  echo "== 5. 新 venv 状态 =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 /opt/corex311-cpython-vllm/bin/python -c \
    'import sys,sysconfig;print("base_prefix",sys.base_prefix);print("pgo","--prefix=/opt/cpython-vllm/v1" in (sysconfig.get_config_var("CONFIG_ARGS") or ""))' 2>&1 | tail -2
  docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 /opt/corex311-cpython-vllm/bin/python -m pip check
  docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 /opt/corex311-cpython-vllm/bin/python -c \
    'import vllm,torch;print("vllm",vllm.__version__,"torch",torch.__version__)' 2>&1 | tail -2

  echo "== 6. 新 venv 源码状态（旧 fastpath 变体）=="
  docker exec corex5-py311 sh -c '
SP=/opt/corex311-cpython-vllm/lib/python3.11/site-packages
for f in vllm/v1/worker/gpu_model_runner.py vllm/envs.py vllm/v1/attention/backends/ilu_flash_attn.py vllm/v1/worker/host_fastpath.py; do
  [ -f "$SP/$f" ] && sha256sum "$SP/$f" || echo "MISSING $f"
done
ls $SP/vllm/_host_opt_native*.so 2>/dev/null || echo "no native so"
'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
