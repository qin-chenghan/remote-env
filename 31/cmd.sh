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
  echo "### 本轮写入：诊断并续传 ${MODEL_ID} 到 ${DEST}。"
  echo "###           上一轮在 9/10 文件处停滞（疑似大文件 Xet 通道在代理后卡死）。"
  echo "###           本轮禁用 Xet、每轮下载加超时、逐轮打印未完成文件大小。"
  echo "###           只读打印现状；下载只写 ${DEST}；不装包、不改系统。"
  set +x

  echo
  echo "== 0. 前置检查（只读） =="
  hostname
  uname -m
  df -BG /home | tail -1
  echo "-- 目标目录现状 --"
  ls -la "$DEST" 2>/dev/null | head -30 || echo "(不存在)"
  du -sh "$DEST" 2>/dev/null || true
  echo "-- 未完成缓存（按大小排序） --"
  find "$DEST/.cache" -type f -printf '%s %p\n' 2>/dev/null | sort -n | tail -10 || true

  if [[ ! -f "$PROXY_SH" ]]; then
      echo "!! 找不到 $PROXY_SH"; exit 2
  fi

  echo
  echo "== 1. 载入代理 =="
  set +u
  source "$PROXY_SH" || { echo "!! source $PROXY_SH 失败"; exit 2; }
  set -u
  echo "-- 代理变量（已脱敏） --"
  env | grep -iE '^(http|https|all|no)_proxy=' \
      | sed -E 's#(://)[^@/]*@#\1***@#' | sort || true

  echo
  echo "== 2. 仓库文件清单与期望大小（经代理） =="
  api="https://hf-mirror.com/api/models/${MODEL_ID}?blobs=true"
  if curl -sS --max-time 30 "$api" -o /tmp/qwen_meta.json; then
      python3 - /tmp/qwen_meta.json <<'PY' || true
import json,sys
d=json.load(open(sys.argv[1]))
for s in d.get("siblings",[]):
    print(f"{s.get('size',-1):12d}  {s.get('rfilename')}")
PY
      rm -f /tmp/qwen_meta.json
  else
      echo "!! 拉取元数据失败，继续尝试下载"
  fi

  echo
  echo "== 3. 续传（HF_HUB_DISABLE_XET=1，每轮 300s，最多 4 轮） =="
  export HF_ENDPOINT="https://hf-mirror.com"
  export HF_HUB_DISABLE_XET=1
  export HF_HUB_DOWNLOAD_TIMEOUT=600
  export HF_HUB_ETAG_TIMEOUT=120
  rc=1
  for attempt in 1 2 3 4; do
      echo "-- attempt $attempt $(date -u +%H:%M:%S) --"
      timeout 300 hf download "$MODEL_ID" --local-dir "$DEST" && { rc=0; break; } || rc=$?
      echo "attempt $attempt 结束 rc=$rc"
      echo "-- 当前目录大小 --"; du -sh "$DEST" 2>/dev/null || true
      echo "-- 未完成缓存 --"
      find "$DEST/.cache" -type f -name "*.incomplete" -printf '%s %p\n' 2>/dev/null | sort -n | tail -5 || true
      (( attempt < 4 )) && sleep 5
  done
  echo "download_rc=$rc"
  if (( rc != 0 )); then
      echo "!! 下载仍未完成；已下载文件与 .incomplete 保留，可继续续传"
      exit "$rc"
  fi

  echo
  echo "== 4. 完整性检查 =="
  for f in config.json tokenizer.json tokenizer_config.json generation_config.json; do
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
