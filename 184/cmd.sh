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
  # 在 184 新 venv 上安装 r10：
  # 1) 校验 r10 包；2) 恢复 pristine（备份在 /tmp/184-new-venv-backup）；
  # 3) 移除旧 fastpath 文件；4) 基线核对；5) install.py 全流程。
  # corex311 不动。

  CON=corex5-py311
  V=/opt/corex311-cpython-vllm
  SITE=$V/lib/python3.11/site-packages
  BAK=/tmp/184-new-venv-backup
  T=/home/qch/transfer
  Z=$T/host-opt-three-pr-validation-20261106-r10-arm64-py311.zip
  PKG=$T/host-opt-pr-validation-20261106-r10

  echo "== 0. r10 包校验 =="
  ls -l "$Z" "$Z.sha256" 2>&1
  ( cd "$T" && sha256sum -c "$(basename "$Z").sha256" )

  echo "== 1. 备份文件完整性（应为 pristine 三件套）=="
  sha256sum "$BAK/envs.py" "$BAK/v1/attention/backends/ilu_flash_attn.py" "$BAK/v1/worker/gpu_model_runner.py" 2>&1

  echo "== 2. 恢复 pristine 并移除旧补丁文件 =="
  cp -p "$BAK/envs.py" "$SITE/vllm/envs.py"
  cp -p "$BAK/v1/attention/backends/ilu_flash_attn.py" "$SITE/vllm/v1/attention/backends/ilu_flash_attn.py"
  cp -p "$BAK/v1/worker/gpu_model_runner.py" "$SITE/vllm/v1/worker/gpu_model_runner.py"
  rm -f "$SITE/vllm/v1/worker/host_fastpath.py"
  rm -f "$SITE/vllm/_host_opt_native.abi3.so" \
        "$SITE/vllm/_host_opt_meta_native.cpython-311-aarch64-linux-gnu.so"
  rm -f "$SITE/vllm/__pycache__/envs.cpython-311"*.pyc
  rm -f "$SITE/vllm/v1/attention/backends/__pycache__/ilu_flash_attn.cpython-311"*.pyc
  rm -f "$SITE/vllm/v1/worker/__pycache__/gpu_model_runner.cpython-311"*.pyc
  echo "restored"

  echo "== 3. r10 基线核对（MANIFEST baseline）=="
  for f in vllm/v1/worker/gpu_model_runner.py \
           vllm/v1/attention/backends/ilu_flash_attn.py \
           vllm/envs.py \
           vllm/model_executor/models/llama.py \
           vllm/model_executor/models/qwen2.py \
           vllm/model_executor/models/qwen3.py \
           vllm/v1/worker/gpu_input_batch.py \
           vllm/v1/utils.py ; do
    sha256sum "$SITE/$f" 2>/dev/null || echo "MISSING $f"
  done

  echo "== 4. 解包 r10 =="
  if [ ! -d "$PKG" ]; then
    unzip -q "$Z" -d "$T" && echo unzipped
  else
    echo "already extracted"
  fi
  ( cd "$PKG" && sha256sum -c SHA256SUMS 2>&1 | tail -5 )

  echo "== 5. dry-run =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= -e VLLM_R10_PACKAGE_DIR="$PKG" \
    "$CON" "$V/bin/python" "$PKG/scripts/install.py" --root "$SITE" --dry-run
  RC=$?
  echo "dry-run rc=$RC"
  if [ "$RC" -ne 0 ]; then echo "DRY-RUN FAILED, abort"; exit 1; fi

  echo "== 6. install =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= -e VLLM_R10_PACKAGE_DIR="$PKG" \
    "$CON" "$V/bin/python" "$PKG/scripts/install.py" --root "$SITE"
  RC=$?
  echo "install rc=$RC"
  if [ "$RC" -ne 0 ]; then echo "INSTALL FAILED, abort"; exit 1; fi

  echo "== 7. check + verify =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= -e VLLM_R10_PACKAGE_DIR="$PKG" \
    "$CON" "$V/bin/python" "$PKG/scripts/install.py" --root "$SITE" --check
  echo "check rc=$?"
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= -e VLLM_R10_PACKAGE_DIR="$PKG" \
    "$CON" "$V/bin/python" "$PKG/scripts/verify.py" --root "$SITE"
  echo "verify rc=$?"

  echo "== 8. 安装后关键 hash =="
  for f in vllm/v1/worker/gpu_model_runner.py vllm/envs.py vllm/v1/attention/backends/ilu_flash_attn.py \
           vllm/v1/worker/host_opt.py vllm/v1/worker/compact_greedy.py vllm/v1/worker/sample_logits_graph.py ; do
    sha256sum "$SITE/$f" 2>/dev/null || echo "MISSING $f"
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
