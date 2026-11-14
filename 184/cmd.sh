#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：确认 r14 四个特性的门控、metadata 归属、torch module fastpath 是否装了、compact_greedy 配置项。
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
  V=/opt/corex311-cpython-vllm
  SP=$V/lib/python3.11/site-packages
  dex() { timeout 60 docker exec "$C" bash -c "$1"; }

  echo "== 1. r14 的 feature 名单与门控 =="
  dex "sed -n '35,60p' $SP/vllm/v1/worker/host_opt.py"
  echo "--- 四特性在 envs.py 的位置 ---"
  dex "sed -n '575,605p' $SP/vllm/envs.py"

  echo "== 2. metadata（PR2）挂在哪 =="
  dex "grep -rn 'VLLM_HOST_OPT' $SP/vllm/v1/attention/backends/ilu_flash_attn.py $SP/vllm/v1/worker/gpu_model_runner.py 2>/dev/null | head -20"
  dex "grep -n 'metadata' $SP/vllm/v1/worker/host_opt.py | head -15"

  echo "== 3. compact_greedy 配置项 =="
  dex "sed -n '645,660p' $SP/vllm/config/compilation.py; sed -n '805,825p' $SP/vllm/config/compilation.py"

  echo "== 4. torch module attr fastpath 是否真的装了 =="
  dex "$V/bin/pip list 2>/dev/null | grep -iE 'torch.module.attr|fastpath|metadata'"
  dex "grep -rl 'TORCH_MODULE_ATTR_FASTPATH' $SP 2>/dev/null | head -5"

  echo "== 5. 参照：32 上 opt 脚本的 compilation-config =="
  grep -rhn "compilation-config" /home/*/litehost_perf*/*.sh 2>/dev/null | sort -u | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
