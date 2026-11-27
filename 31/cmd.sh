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
  echo "### 本轮写入：继续下载 ${MODEL_ID} 到 ${DEST}。"
  echo "###           上一轮代理访问 huggingface.co 返回 504；本轮先探测 hf-mirror 再下载。"
  echo "###           不改系统、不装包、不启动服务。"
  set +x

  echo
  echo "== 0. 前置检查（只读） =="
  hostname
  uname -m
  df -BG /home | tail -1
  echo "-- 目标目录当前内容 --"
  ls -la "$DEST" 2>/dev/null | head -20 || echo "(不存在)"
  du -sh "$DEST" 2>/dev/null || true

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
  echo "== 2. 连通性探测（HTTP 状态码） =="
  probe() {  # probe <name> <url> [direct]
      local name="$1" url="$2" direct="${3:-}" code
      if [[ -n "$direct" ]]; then
          code=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
                      -u all_proxy -u ALL_PROXY \
                      curl -sS -o /dev/null -w '%{http_code}' --max-time 25 "$url" 2>/dev/null) || code=ERR
      else
          code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 25 "$url" 2>/dev/null) || code=ERR
      fi
      printf '%-24s %s\n' "$name" "$code"
      [[ "$code" == 200 ]]
  }

  hfmirror_proxy=0; hfmirror_direct=0; hf_proxy=0
  probe hf-mirror-via-proxy "https://hf-mirror.com/api/models/${MODEL_ID}" && hfmirror_proxy=1
  probe hf-mirror-direct   "https://hf-mirror.com/api/models/${MODEL_ID}" direct && hfmirror_direct=1
  probe hf-via-proxy       "https://huggingface.co/api/models/${MODEL_ID}" && hf_proxy=1

  endpoint=""; use_proxy=1
  if (( hfmirror_proxy )); then
      endpoint="https://hf-mirror.com"; use_proxy=1
  elif (( hfmirror_direct )); then
      endpoint="https://hf-mirror.com"; use_proxy=0
  elif (( hf_proxy )); then
      endpoint="https://huggingface.co"; use_proxy=1
  fi
  echo "endpoint=${endpoint:-none} use_proxy=$use_proxy"

  if [[ -z "$endpoint" ]]; then
      echo "!! hf-mirror（代理/直连）和 huggingface.co 都不可达，本轮不下载"
      echo "!! 目标目录保留现状，便于下一轮换 ModelScope 或其他源"
      exit 3
  fi

  echo
  echo "== 3. 下载 ${MODEL_ID}（endpoint=$endpoint，最多 3 次） =="
  rc=1
  for attempt in 1 2 3; do
      echo "-- attempt $attempt $(date -u +%H:%M:%S) --"
      if (( use_proxy )); then
          HF_ENDPOINT="$endpoint" HF_HUB_DOWNLOAD_TIMEOUT=120 HF_HUB_ETAG_TIMEOUT=60 \
              hf download "$MODEL_ID" --local-dir "$DEST" && { rc=0; break; } || rc=$?
      else
          env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
              HF_ENDPOINT="$endpoint" HF_HUB_DOWNLOAD_TIMEOUT=120 HF_HUB_ETAG_TIMEOUT=60 \
              hf download "$MODEL_ID" --local-dir "$DEST" && { rc=0; break; } || rc=$?
      fi
      echo "attempt $attempt 失败 rc=$rc"
      (( attempt < 3 )) && sleep 10
  done
  echo "download_rc=$rc"
  if (( rc != 0 )); then
      echo "!! 下载仍失败；已下载文件保留，可重跑续传"
      exit "$rc"
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
