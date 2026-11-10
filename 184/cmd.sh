#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 本次任务：把 /opt/corex311 上的 r3 卸载，改装 r10。
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
  SITE=/opt/corex311/lib/python3.11/site-packages
  PY=/opt/corex311/bin/python3
  R3=$(find /home -maxdepth 4 -type d -name 'host-opt-pr-validation-*r3*' 2>/dev/null | head -1)
  R10=/home/qch/transfer/host-opt-pr-validation-20261106-r10

  echo "== preflight: any model service running? =="
  ps -eo pid,args 2>/dev/null | grep -E 'vllm.entrypoints.openai.api_server|bench_driver.py' | grep -v grep | cut -c1-160
  if ps -eo pid,args 2>/dev/null | grep -E 'vllm.entrypoints.openai.api_server|bench_driver.py' | grep -v grep >/dev/null; then
    echo "ABORT: 有模型服务/压测在跑，先把它们停掉再执行"
    exit 3
  fi

  echo "== locate packages =="
  echo "R3=$R3"
  echo "R10=$R10"
  ls -d "$R3/scripts/install.py" "$R10/scripts/install.py" 2>&1

  echo "== r3 uninstall support =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME "$PY" "$R3/scripts/install.py" --help 2>&1 | grep -iE 'uninstall|restore|check|root' | head -10

  echo "== backup base vllm =="
  mkdir -p /home/qch/backup
  tar -czf "/home/qch/backup/corex311-vllm-pre-r10-$TS.tar.gz" -C "$SITE" vllm 2>&1 | tail -3
  ls -lh "/home/qch/backup/corex311-vllm-pre-r10-$TS.tar.gz" 2>&1

  echo "== state before =="
  docker exec corex5-py311 bash -c "ls \$0/vllm/v1/worker/host_fastpath.py \$0/vllm/.host-opt-pr-backup 2>&1; ls \$0/vllm/_host_opt_native*.so 2>&1" "$SITE" 2>&1

  echo "== uninstall r3 =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME "$PY" "$R3/scripts/install.py" \
    --root "$SITE" --uninstall 2>&1 | tail -20
  RC_OFF=${PIPESTATUS[0]}
  echo "uninstall rc=$RC_OFF"

  echo "== state after uninstall =="
  docker exec corex5-py311 bash -c "ls \$0/vllm/v1/worker/host_fastpath.py \$0/vllm/.host-opt-pr-backup 2>&1; ls \$0/vllm/_host_opt_native*.so \$0/vllm/_host_opt_meta_native*.so 2>&1" "$SITE" 2>&1

  echo "== r10 dry-run (baseline must match) =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME "$PY" "$R10/scripts/install.py" \
    --root "$SITE" --dry-run 2>&1 | tail -15
  RC_DRY=${PIPESTATUS[0]}
  echo "dry-run rc=$RC_DRY"
  if [ "$RC_DRY" -ne 0 ]; then
    echo "ABORT: dry-run 未通过，不安装 r10"
    exit 4
  fi

  echo "== install r10 =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME \
    VLLM_R10_PACKAGE_DIR="$R10" VLLM_SITE_ROOT="$SITE" \
    "$PY" "$R10/scripts/install.py" --root "$SITE" 2>&1 | tail -25
  RC_INST=${PIPESTATUS[0]}
  echo "install rc=$RC_INST"

  echo "== check r10 =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME "$PY" "$R10/scripts/install.py" \
    --root "$SITE" --check 2>&1 | tail -8

  echo "== hashes (base, should equal r10 MANIFEST.patched) =="
  docker exec corex5-py311 bash -c "cd \$0 && sha256sum \
    vllm/v1/worker/gpu_model_runner.py vllm/envs.py vllm/v1/attention/backends/ilu_flash_attn.py \
    vllm/v1/worker/host_opt.py vllm/v1/worker/compact_greedy.py vllm/v1/worker/sample_logits_graph.py \
    vllm/config/compilation.py vllm/config/vllm.py \
    vllm/model_executor/models/llama.py vllm/model_executor/models/qwen2.py vllm/model_executor/models/qwen3.py" "$SITE" 2>&1

  echo "== import smoke =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME "$PY" -c \
    "import vllm, torch; print('vllm', vllm.__version__); print('torch', torch.__version__)" 2>&1 | tail -4

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
