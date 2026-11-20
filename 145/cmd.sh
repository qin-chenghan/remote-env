#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：清理预热产物——旧 /tmp 缓存 + 三个 priming 运行目录；保留固定缓存目录。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
TOOLS=/home/huawei_ts_program/litehost_perf_opt
KEEP=/home/huawei_ts_program/inductor_cache_py312
OLD=/tmp/torchinductor_root
RUNS="prime_py312_128 prime_py312_128_cached confirm_py312_128"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 确认没有服务在跑 =="
  # Bracket trick: pgrep must not match its own bash -lc command line.
  if docker exec "$C" bash -lc 'pgrep -f "vllm[.]entrypoints[.]openai[.]api_server" >/dev/null 2>&1'; then
    echo "!! 仍有 api_server 在跑，拒绝清理"
    docker exec "$C" bash -lc 'pgrep -af "vllm[.]entrypoints[.]openai[.]api_server" | head -3'
    exit 5
  fi
  if ss -ltn 2>/dev/null | grep -qE ':(8948|8848)\b'; then
    echo "!! 8948/8848 仍在监听，拒绝清理"
    exit 5
  fi
  echo "无 api_server，端口空闲"

  echo "== 2. 清理前 =="
  docker exec "$C" bash -lc "
    du -sh $OLD 2>/dev/null || echo '旧缓存已不存在'
    echo \"keep cache files=\$(find $KEEP -name '*.py' 2>/dev/null | wc -l)\"
    for d in $RUNS; do du -sh $TOOLS/vllmBench/\$d 2>/dev/null; done
  "

  echo "== 3. 删除 =="
  docker exec "$C" bash -lc "rm -rf $OLD; echo 'old cache removed'"
  for d in $RUNS; do
    docker exec "$C" bash -lc "rm -rf $TOOLS/vllmBench/$d"
  done
  echo "run dirs removed"

  echo "== 4. 清理后 =="
  docker exec "$C" bash -lc "
    du -sh $OLD 2>/dev/null || echo 'old cache gone'
    echo \"keep cache files=\$(find $KEEP -name '*.py' 2>/dev/null | wc -l)\"
    du -sh $KEEP 2>/dev/null
    for d in $RUNS; do [ -d $TOOLS/vllmBench/\$d ] && echo \"still exists: \$d\"; done
    echo '-- vllmBench 剩余目录 --'
    ls $TOOLS/vllmBench 2>/dev/null | head -6
  " 2>&1 | head -14

  echo "== 5. 缓存仍可用 =="
  docker exec "$C" bash -lc "\
    TORCHINDUCTOR_CACHE_DIR=$KEEP /usr/local/bin/python3 -c \
    'import torch; print(\"torch\", torch.__version__)'" 2>&1 | tail -3

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
