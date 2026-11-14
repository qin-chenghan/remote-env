#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：确认 timeline 用的解释器、LightHostWorker 是否让 host_opt 走原始路径、登录 shell 的 PYTHONPATH。
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
  C=corex5-py311
  SP=/opt/corex311-cpython-vllm/lib/python3.11/site-packages
  dex() { timeout 60 docker exec "$C" bash -c "$1"; }

  echo "== 1. timeline 默认的 python3 到底是哪个 =="
  dex 'bash -lc "command -v python3; readlink -f \$(command -v python3)"'
  dex '/opt/corex311/bin/python3 -c "import sys,sysconfig;print(sys.executable);print(sys.base_prefix);print(sysconfig.get_config_var(\"CONFIG_ARGS\"))"'
  echo "--- 对比 bench 用的 PGO 解释器 ---"
  dex '/opt/corex311-cpython-vllm/bin/python3 -c "import sys,sysconfig;print(sys.executable);print(sys.base_prefix);print(sysconfig.get_config_var(\"CONFIG_ARGS\"))"'

  echo "== 2. 登录 shell 里 PYTHONPATH 是否被 unset =="
  dex 'bash -lc "echo PYTHONPATH=[\${PYTHONPATH:-<empty>}]"'
  dex 'bash -lc "grep -rn PYTHONPATH /etc/profile /etc/profile.d /root/.bashrc 2>/dev/null | head -10"'

  echo "== 3. LightHostWorker 是什么（是否 runner 子类）=="
  dex 'cat /home/huawei_ts_program/litehost_perf_opt/light_host_worker.py'

  echo "== 4. host_opt 的 supported 语义与调用点 =="
  dex "sed -n '1,40p' $SP/vllm/v1/worker/host_opt.py"
  dex "grep -rn 'supported' $SP/vllm/v1/worker/host_opt.py $SP/vllm/v1/worker/gpu_model_runner.py | head -20"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
