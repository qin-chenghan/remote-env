#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读；宿主机执行，/opt 属于容器，走 docker exec。
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
  NEW=/opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm
  BASE=/opt/corex311/lib/python3.11/site-packages/vllm

  echo "== r10 files present? =="
  docker exec corex5-py311 bash -c "ls -l $NEW/v1/worker/host_opt.py $NEW/v1/worker/compact_greedy.py $NEW/v1/worker/sample_logits_graph.py $NEW/.host-opt-pr-backup 2>&1 | head" 2>&1

  echo "== r10 hashes (new venv) =="
  docker exec corex5-py311 bash -c "cd $NEW/.. && sha256sum \
    vllm/v1/worker/gpu_model_runner.py vllm/envs.py vllm/v1/attention/backends/ilu_flash_attn.py \
    vllm/v1/worker/host_opt.py vllm/v1/worker/compact_greedy.py vllm/v1/worker/sample_logits_graph.py \
    vllm/config/compilation.py vllm/config/vllm.py \
    vllm/model_executor/models/llama.py vllm/model_executor/models/qwen2.py vllm/model_executor/models/qwen3.py" 2>&1

  echo "== r10 switches wired =="
  docker exec corex5-py311 bash -c "grep -n 'VLLM_HOST_OPT\|VLLM_COMPACT_GREEDY\|sample_logits_cudagraph' $NEW/envs.py | head -20" 2>&1
  docker exec corex5-py311 bash -c "grep -n 'sample_logits_cudagraph' $NEW/config/compilation.py | head -8" 2>&1

  echo "== base venv patch generation =="
  docker exec corex5-py311 bash -c "ls $BASE/v1/worker/host_fastpath.py $BASE/v1/worker/host_opt.py 2>&1; grep -l 'VLLM_HOST_FASTPATH' $BASE/envs.py 2>/dev/null" 2>&1

  echo "== find r10 package dir =="
  find /home -maxdepth 4 -type d -name 'host-opt-pr-validation-*r10*' 2>/dev/null | head -5

  echo "== install.py --check =="
  D=$(find /home -maxdepth 4 -type d -name 'host-opt-pr-validation-*r10*' 2>/dev/null | head -1)
  if [ -n "$D" ] && [ -f "$D/scripts/install.py" ]; then
    docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME \
      /opt/corex311-cpython-vllm/bin/python3 "$D/scripts/install.py" \
      --root "$NEW/.." --check 2>&1 | tail -12
  else
    echo "r10 package dir not found on host path"
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
