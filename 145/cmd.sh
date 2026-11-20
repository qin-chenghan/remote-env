#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：不动容器，验证给 vllm 容器补 LD_LIBRARY_PATH 后 torch/mock 是否正常。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

LIB=/usr/local/corex/lib64:/usr/local/openmpi/lib:/usr/local/lib

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. vllm 容器：补 LD_LIBRARY_PATH 后 import torch =="
  docker exec -e LD_LIBRARY_PATH="$LIB" vllm \
    /opt/corex311/bin/python3 -c \
    'import torch; print("torch", torch.__version__, "cuda_available", torch.cuda.is_available())' 2>&1 | tail -4

  echo "== 2. 同环境下 mock 是否能激活 =="
  docker exec -e LD_LIBRARY_PATH="$LIB" \
    -e PYTHONPATH=/home/qch/mock_vllm vllm \
    /opt/corex311/bin/python3 -c 'import mock_gpu.autoload' 2>&1 | tail -4

  echo "== 3. 容器内模型与工具是否就绪 =="
  docker exec vllm bash -lc '
    du -sh /home/model/Qwen3-32B-W8A8 2>/dev/null
    ls /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base_mock.sh 2>/dev/null || echo "缺 mock 版 harness"
  ' 2>&1 | head -4

  echo "== 4. 端口 =="
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 空闲"

  echo "== 5. 建议的运行方式（不重建容器） =="
  echo "docker exec vllm bash -lc '"
  echo "  export LD_LIBRARY_PATH=$LIB"
  echo "  cd /home/huawei_ts_program/litehost_perf_opt"
  echo "  MODEL_PATH=/home/model/Qwen3-32B-W8A8 TEST_ID=lite_vllm_xxx HOST_MEASURE=lite \\"
  echo "    bash vllmBench_lite_base_mock.sh'"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
