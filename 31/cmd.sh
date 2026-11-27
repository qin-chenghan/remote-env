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
BIG="model.safetensors"
URL="https://hf-mirror.com/${MODEL_ID}/resolve/main/${BIG}"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "### 本轮写入：绕开 hf 的 ETag 重下逻辑，用 curl 断点续传 ${BIG}。"
  echo "###           已确认 .cache 里有两个不同 etag 的半成品（268MB / 409MB），"
  echo "###           每次重试都从 0 重来，所以到不了 1.5GB。"
  echo "###           只读探测 + 只写 ${DEST}；不装包、不改系统。"
  set +x

  echo
  echo "== 0. 现状（只读） =="
  df -BG /home | tail -1
  ls -la "$DEST" 2>/dev/null | head -20 || echo "(不存在)"
  du -sh "$DEST" 2>/dev/null || true
  echo "-- 半成品 --"
  find "$DEST/.cache" -type f -name "*.incomplete" -printf '%s %p\n' 2>/dev/null | sort -n || true

  if [[ ! -f "$PROXY_SH" ]]; then
      echo "!! 找不到 $PROXY_SH"; exit 2
  fi

  echo
  echo "== 1. 载入代理 =="
  set +u
  source "$PROXY_SH" || { echo "!! source $PROXY_SH 失败"; exit 2; }
  set -u
  env | grep -iE '^(http|https|all|no)_proxy=' \
      | sed -E 's#(://)[^@/]*@#\1***@#' | sort || true

  echo
  echo "== 2. 期望大小与 sha256（经代理取元数据） =="
  if curl -sS --max-time 30 "https://hf-mirror.com/api/models/${MODEL_ID}?blobs=true" -o /tmp/qwen_meta.json; then
      python3 - /tmp/qwen_meta.json <<'PY' | tee /tmp/qwen_big.txt || true
import json,sys
d=json.load(open(sys.argv[1]))
for s in d.get("siblings",[]):
    lfs=s.get("lfs") or {}
    print(f"{s.get('rfilename')}\t{s.get('size',lfs.get('size',-1))}\t{lfs.get('oid','')}")
PY
      rm -f /tmp/qwen_meta.json
      read -r _ EXPECTED_SIZE EXPECTED_SHA < <(grep -P "^${BIG}\t" /tmp/qwen_big.txt || true)
  else
      echo "!! 元数据拉取失败，继续尝试下载"
  fi
  echo "expected_size=${EXPECTED_SIZE:-unknown} expected_sha=${EXPECTED_SHA:-unknown}"

  echo
  echo "== 3. 头探测与 Range 支持 =="
  curl -sSI --max-time 30 "$URL" | tr -d '\r' | grep -iE '^(HTTP/|content-length:|accept-ranges:|etag:|location:)' | head -12 || true
  code=$(curl -sS -o /tmp/qwen_head1m.bin -w '%{http_code}' -r 0-1048575 --max-time 90 "$URL") || code=ERR
  echo "range_status=$code head_bytes=$(stat -c %s /tmp/qwen_head1m.bin 2>/dev/null || echo 0)"

  echo
  echo "== 4. 用已有半成品做种子（前缀校验一致才用） =="
  seed=$(find "$DEST/.cache" -type f -name "*.incomplete" -printf '%s %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
  if [[ -n "${seed:-}" && -f /tmp/qwen_head1m.bin ]]; then
      seed_head=$(head -c 1048576 "$seed" | sha256sum | cut -d' ' -f1)
      remote_head=$(sha256sum /tmp/qwen_head1m.bin | cut -d' ' -f1)
      echo "seed=$seed"
      echo "seed_head=$seed_head"
      echo "remote_head=$remote_head"
      if [[ "$seed_head" == "$remote_head" && ! -s "$DEST/$BIG" ]]; then
          cp --sparse=always "$seed" "$DEST/$BIG"
          echo "已用半成品播种：$(stat -c %s "$DEST/$BIG") bytes"
      fi
  fi
  if [[ ! -s "$DEST/$BIG" ]]; then
      echo "无可用种子，从 0 开始"
  fi

  echo
  echo "== 5. curl 断点续传（30s 打印一次进度） =="
  start_size=$(stat -c %s "$DEST/$BIG" 2>/dev/null || echo 0)
  echo "start_size=$start_size"
  curl -sS -L -C - --retry 10 --retry-all-errors --retry-delay 5 \
      --speed-limit 10240 --speed-time 90 --max-time 1800 \
      -o "$DEST/$BIG" "$URL" &
  cpid=$!
  while kill -0 "$cpid" 2>/dev/null; do
      sleep 30
      echo "progress $(date -u +%H:%M:%S) size=$(stat -c %s "$DEST/$BIG" 2>/dev/null || echo 0)"
  done
  wait "$cpid"; rc=$?
  echo "curl_rc=$rc final_size=$(stat -c %s "$DEST/$BIG" 2>/dev/null || echo 0)"
  rm -f /tmp/qwen_head1m.bin /tmp/qwen_big.txt

  echo
  echo "== 6. 完整性检查 =="
  actual_size=$(stat -c %s "$DEST/$BIG" 2>/dev/null || echo 0)
  echo "size=$actual_size expected=${EXPECTED_SIZE:-unknown}"
  if [[ -n "${EXPECTED_SIZE:-}" && "$actual_size" != "$EXPECTED_SIZE" ]]; then
      echo "!! 大小不匹配，文件不完整；可重跑本脚本继续续传"
      exit 4
  fi
  if [[ -n "${EXPECTED_SHA:-}" ]]; then
      echo "-- 计算 sha256（约 1.5GB，稍等） --"
      actual_sha=$(sha256sum "$DEST/$BIG" | cut -d' ' -f1)
      echo "sha256=$actual_sha expected=$EXPECTED_SHA"
      if [[ "$actual_sha" != "$EXPECTED_SHA" ]]; then
          echo "!! sha256 不匹配，需删除后重下"
          exit 5
      fi
  fi
  for f in config.json tokenizer.json tokenizer_config.json generation_config.json; do
      [[ -f "$DEST/$f" ]] && echo "ok   $f" || echo "MISS $f"
  done
  echo "-- 文件列表 --"
  ls -lh "$DEST" | head -30
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
