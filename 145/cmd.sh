#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：145 上 mock 环境已就绪（镜像已载入、容器在跑、mock 已激活），只做模型冒烟。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

MODEL=/home/model/Qwen3-32B-W8A8
CONTAINER=corex5-py311-mock

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 前置检查 =="
  docker ps --filter "name=$CONTAINER" --format '{{.Names}} {{.Status}}' | grep -q Up \
    || { echo "!! 容器 $CONTAINER 没在跑"; exit 3; }
  [ -f "$MODEL/config.json" ] || { echo "!! 缺 $MODEL，模型还没传完"; exit 3; }
  du -sh "$MODEL"
  ls "$MODEL" | head -8
  df -h /home | tail -1
  free -g | head -1

  echo "== 2. 模型冒烟（真实权重，CPU 上一次生成）=="
  docker exec "$CONTAINER" bash -lc '
    cd /tmp && PYTHONPATH=/home/qch/mock_vllm MOCK_PREFILL=1 \
    /opt/corex311/bin/python3 - <<"PY" 2>&1 | tail -15
from vllm import LLM, SamplingParams
llm = LLM(model="/home/model/Qwen3-32B-W8A8", trust_remote_code=True,
          max_model_len=512, tensor_parallel_size=1, gpu_memory_utilization=0.2,
          disable_log_stats=True,
          compilation_config={"cudagraph_mode": "NONE", "mode": 0})
out = llm.generate(["hi"], SamplingParams(max_tokens=8, temperature=0.0,
                                           top_p=1.0, top_k=-1))
print("SMOKE OK, tokens:", out[0].outputs[0].token_ids)
PY
  '

  echo "== 3. 结果 =="
  echo "出现 SMOKE OK 即模型 + engine + mock 路径可用"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
