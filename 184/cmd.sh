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
  # 修正版：pristine 文件用 docker cp 送进容器，恢复/删除/校验都在容器内执行。
  # 然后 dry-run -> install -> check -> verify。corex311 不动。

  CON=corex5-py311
  V=/opt/corex311-cpython-vllm
  SITE=$V/lib/python3.11/site-packages
  BAK=/tmp/184-new-venv-backup
  T=/home/qch/transfer
  Z=$T/host-opt-three-pr-validation-20261106-r10-arm64-py311.zip
  PKG=$T/host-opt-pr-validation-20261106-r10

  echo "== 0. 备份校验（宿主）=="
  sha256sum "$BAK/envs.py" "$BAK/v1/attention/backends/ilu_flash_attn.py" "$BAK/v1/worker/gpu_model_runner.py"

  echo "== 1. docker cp pristine 文件进容器 =="
  docker cp "$BAK/envs.py" "$CON:$SITE/vllm/envs.py"
  docker cp "$BAK/v1/attention/backends/ilu_flash_attn.py" "$CON:$SITE/vllm/v1/attention/backends/ilu_flash_attn.py"
  docker cp "$BAK/v1/worker/gpu_model_runner.py" "$CON:$SITE/vllm/v1/worker/gpu_model_runner.py"

  echo "== 2. 容器内删除旧补丁文件与陈旧 pyc =="
  docker exec "$CON" sh -c "
SP=$SITE
rm -f \$SP/vllm/v1/worker/host_fastpath.py
rm -f \$SP/vllm/_host_opt_native.abi3.so
rm -f \$SP/vllm/_host_opt_meta_native.cpython-311-aarch64-linux-gnu.so
rm -f \$SP/vllm/__pycache__/envs.cpython-311*.pyc
rm -f \$SP/vllm/v1/attention/backends/__pycache__/ilu_flash_attn.cpython-311*.pyc
rm -f \$SP/vllm/v1/worker/__pycache__/gpu_model_runner.cpython-311*.pyc
echo removed"

  echo "== 3. 容器内基线核对（r10 MANIFEST baseline）=="
  docker exec "$CON" sh -c "
SP=$SITE
for f in vllm/v1/worker/gpu_model_runner.py \
         vllm/v1/attention/backends/ilu_flash_attn.py \
         vllm/envs.py \
         vllm/model_executor/models/llama.py \
         vllm/model_executor/models/qwen2.py \
         vllm/model_executor/models/qwen3.py \
         vllm/v1/worker/gpu_input_batch.py \
         vllm/v1/utils.py ; do
  sha256sum \$SP/\$f 2>/dev/null || echo MISSING \$f
done"

  echo "== 4. dry-run =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= -e VLLM_R10_PACKAGE_DIR="$PKG" \
    "$CON" "$V/bin/python" "$PKG/scripts/install.py" --root "$SITE" --dry-run
  RC=$?
  echo "dry-run rc=$RC"
  if [ "$RC" -ne 0 ]; then echo "DRY-RUN FAILED, abort"; exit 1; fi

  echo "== 5. install =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= -e VLLM_R10_PACKAGE_DIR="$PKG" \
    "$CON" "$V/bin/python" "$PKG/scripts/install.py" --root "$SITE"
  RC=$?
  echo "install rc=$RC"
  if [ "$RC" -ne 0 ]; then echo "INSTALL FAILED, abort"; exit 1; fi

  echo "== 6. check + verify =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= -e VLLM_R10_PACKAGE_DIR="$PKG" \
    "$CON" "$V/bin/python" "$PKG/scripts/install.py" --root "$SITE" --check
  echo "check rc=$?"
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= -e VLLM_R10_PACKAGE_DIR="$PKG" \
    "$CON" "$V/bin/python" "$PKG/scripts/verify.py" --root "$SITE"
  echo "verify rc=$?"

  echo "== 7. 安装后关键 hash =="
  docker exec "$CON" sh -c "
SP=$SITE
for f in vllm/v1/worker/gpu_model_runner.py vllm/envs.py vllm/v1/attention/backends/ilu_flash_attn.py \
         vllm/v1/worker/host_opt.py vllm/v1/worker/compact_greedy.py vllm/v1/worker/sample_logits_graph.py ; do
  sha256sum \$SP/\$f 2>/dev/null || echo MISSING \$f
done"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
