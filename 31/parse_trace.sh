#!/usr/bin/env bash
# 只读解析已导出的 Perfetto trace，输出 GPU/CPU 时间占比。
# 用法：bash 31/parse_trace.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

IMAGE="${IMAGE:-local/vllm-metax:0.21.0-arm64-c500}"
TRACE_HOST="${TRACE_HOST:-/home/qch/qwen06_profile}"
TRACE_NAME="${TRACE_NAME:-offline_bs240_in1024_out1024.json}"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### script: parse-trace-31（只读：解析 $TRACE_HOST/$TRACE_NAME）"
  echo
  echo "### 本轮写入：只写本 log；不跑模型、不改系统、不留容器。"
  echo "### 预计：json.load 1.2 GB，约 3-8 分钟（取决于内存和磁盘）。"
  set +x

  echo
  echo "== 0. 前置检查（只读） =="
  date
  ls -lh "$TRACE_HOST" | head -10
  [[ -f "$TRACE_HOST/$TRACE_NAME" ]] || { echo "!! 找不到 $TRACE_HOST/$TRACE_NAME"; exit 2; }
  df -h /home | tail -1
  free -g | head -3

  echo
  echo "== 1. 容器内解析（写入：无） =="
  docker run --rm -v "$TRACE_HOST":/profile:ro -v "$DIR":/scripts:ro \
      -e TRACE_FILE="/profile/$TRACE_NAME" \
      "$IMAGE" bash -lc 'python3 /scripts/parse_trace.py "$TRACE_FILE"'
  echo "parse_rc=$?"

  echo
  echo "### 完成：GPU/CPU 时间占比"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
