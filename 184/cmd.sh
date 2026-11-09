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
  # 只读：定位 VLLM_DISABLE_DECODE_FASTPATH 的引用上下文与来源。

  CON=corex5-py311
  SP=/opt/corex311/lib/python3.11/site-packages

  echo "== 1. gpu_model_runner 中的上下文 =="
  docker exec "$CON" sh -c "grep -n -B8 -A14 VLLM_DISABLE_DECODE_FASTPATH $SP/vllm/v1/worker/gpu_model_runner.py"

  echo "== 2. 当前文件 hash 与备份 =="
  docker exec "$CON" sh -c "
sha256sum $SP/vllm/v1/worker/gpu_model_runner.py
sha256sum $SP/.host-opt-pr-backup/vllm/v1/worker/gpu_model_runner.py 2>/dev/null || echo 'no backup file'
grep -c VLLM_DISABLE_DECODE_FASTPATH $SP/.host-opt-pr-backup/vllm/v1/worker/gpu_model_runner.py 2>/dev/null || true
"

  echo "== 3. 其他 venv / r3 交付包 / 全盘来源 =="
  docker exec "$CON" sh -c "
echo '-- 新 venv --'
grep -rl VLLM_DISABLE_DECODE_FASTPATH /opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm 2>/dev/null | head -5 || echo none
echo '-- r3 交付包 --'
grep -rn VLLM_DISABLE_DECODE_FASTPATH /home/qch/transfer/host-opt-pr-validation-20261103-r3 2>/dev/null | head -10 || echo none
echo '-- transfer 其他 --'
grep -rl VLLM_DISABLE_DECODE_FASTPATH /home/qch/transfer 2>/dev/null | grep -v cmd.sh | head -10 || echo none
echo '-- 谁定义了这个 env 名（vllm envs）--'
grep -rn 'DISABLE_DECODE_FASTPATH' $SP/vllm/envs.py 2>/dev/null || echo 'not in envs.py'
"

  echo "== 4. 运行中进程环境与启动命令 =="
  docker exec "$CON" sh -c '
for p in $(pgrep -f vllm.entrypoints.openai.api_server 2>/dev/null); do
  echo "-- PID $p --"
  tr "\0" "\n" < /proc/$p/environ 2>/dev/null | grep -E "VLLM_DISABLE_DECODE_FASTPATH|VLLM_HOST_FASTPATH|TORCH_MODULE_ATTR" | sort
  echo -n "  cmdline: "; tr "\0" " " < /proc/$p/cmdline | cut -c1-400; echo
done
'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
