#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

MODEL_ID="${MODEL_ID:-Qwen/Qwen3-0.6B}"
DEST="${DEST:-/home/qch/models/Qwen3-0.6B}"
PROXY_SH="${PROXY_SH:-/home/qch/env/set_proxy.sh}"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "### 本轮写入：在 31 上创建 /home/qch/models，下载 ${MODEL_ID} 到 ${DEST}。"
  echo "###           使用 ${PROXY_SH} 的代理；不改系统、不装包、不启动服务。"
  echo "###           预计 1.2GB 左右，视代理速度约 1–5 分钟。"
  set +x

  echo
  echo "== 0. 前置检查（只读） =="
  hostname
  uname -m
  df -BG /home | tail -1
  avail_gb=$(df -BG --output=avail /home | tail -1 | tr -dc '0-9')
  echo "home_avail_gb=${avail_gb:-unknown}"
  if [[ -n "${avail_gb:-}" ]] && (( avail_gb < 5 )); then
      echo "!! /home 可用不足 5G，停止"; exit 2
  fi

  if [[ -f "$PROXY_SH" ]]; then
      echo "proxy_script=$PROXY_SH（存在；内容不打印，避免泄露凭据）"
  else
      echo "!! 找不到 $PROXY_SH"; exit 2
  fi

  echo
  echo "== 1. 载入代理 =="
  # shellcheck disable=SC1090
  set +u
  source "$PROXY_SH" || { echo "!! source $PROXY_SH 失败"; exit 2; }
  set -u
  echo "-- 代理变量（已脱敏） --"
  env | grep -iE '^(http|https|all|no)_proxy=' \
      | sed -E 's#(://)[^@/]*@#\1***@#' | sort || true
  echo "HF_ENDPOINT=${HF_ENDPOINT:-unset}"

  echo
  echo "== 2. 目标目录 =="
  mkdir -p "$(dirname "$DEST")"
  echo "DEST=$DEST"
  if [[ -f "$DEST/config.json" ]]; then
      echo "已存在 config.json，跳过下载；仅做完整性检查。"
  else
      echo "目标不存在，开始下载。"
      echo "-- 可用下载工具 --"
      for t in hf huggingface-cli modelscope git-lfs python3; do
          printf '%-16s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo no)"
      done

      echo
      echo "== 3. 下载 ${MODEL_ID} =="
      rc=1
      export HF_HUB_ENABLE_HF_TRANSFER=0
      if command -v hf >/dev/null 2>&1; then
          echo "-- 使用 hf download --"
          hf download "$MODEL_ID" --local-dir "$DEST" && rc=0 || rc=$?
      elif command -v huggingface-cli >/dev/null 2>&1; then
          echo "-- 使用 huggingface-cli download --"
          huggingface-cli download "$MODEL_ID" --local-dir "$DEST" && rc=0 || rc=$?
      elif python3 -c 'import huggingface_hub' >/dev/null 2>&1; then
          echo "-- 使用 huggingface_hub.snapshot_download --"
          python3 - "$MODEL_ID" "$DEST" <<'PY' && rc=0 || rc=$?
import sys
from huggingface_hub import snapshot_download
snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2])
PY
      elif command -v modelscope >/dev/null 2>&1; then
          echo "-- 使用 modelscope download --"
          modelscope download --model "$MODEL_ID" --local_dir "$DEST" && rc=0 || rc=$?
      else
          echo "!! 没有可用的下载工具（hf / huggingface-cli / huggingface_hub / modelscope）"
          rc=3
      fi
      echo "download_rc=$rc"
      if (( rc != 0 )); then
          echo "!! 下载失败，保留已下载文件，便于重跑续传"; exit "$rc"
      fi
  fi

  echo
  echo "== 4. 完整性检查 =="
  for f in config.json tokenizer.json tokenizer_config.json; do
      [[ -f "$DEST/$f" ]] && echo "ok   $f" || echo "MISS $f"
  done
  if compgen -G "$DEST/*.safetensors" >/dev/null || compgen -G "$DEST/*.bin" >/dev/null; then
      echo "ok   权重文件"
  else
      echo "MISS 权重文件（*.safetensors / *.bin）"
  fi
  echo "-- 文件列表 --"
  ls -lh "$DEST" | head -30
  echo "-- 目录大小 --"
  du -sh "$DEST" 2>/dev/null || true

  echo
  echo "### 完成：MODEL_DIR=$DEST"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
