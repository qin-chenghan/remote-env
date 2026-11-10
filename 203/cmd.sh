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
  # 用 203 现成的 vllmBench_lite_taskset.sh 跑一次基线（HOST_MEASURE=off，单 case 短跑）。

  echo "== 1. 前置检查 =="
  docker exec corex5-py311 bash -lc '
    command -v curl || echo "NO curl"
    command -v ixsmi || echo "NO ixsmi (脚本会警告并跳过显存预检)"
    ls -d /opt/corex311/bin/python3
    ls -d /home/models/Qwen3-32B-W8A8
    df -h /home | tail -1
mktemp -d >/dev/null && echo "tmp writable"
  ' 2>&1 | head -10

  echo "== 2. 运行基线（单 case 128/2048，32 prompts，4 warmup）=="
  TID="baseline_$(date +%H%M%S)"
  timeout 1200 docker exec \
    -e MODEL_PATH=/home/models/Qwen3-32B-W8A8 \
    -e HOST_MEASURE=off \
    -e NUM_PROMPTS=32 \
    -e NUM_WARMUPS=4 \
    -e CASE_INTERVAL=0 \
    -e TEST_ID="$TID" \
    -e CASES_FILE=/tmp/cases_one.txt \
    corex5-py311 bash -lc '
      printf "128 2048\n" > /tmp/cases_one.txt
      cd /home/qch/scripts/litehost_perf && bash vllmBench_lite_taskset.sh
    ' 2>&1 | tail -60
  echo "run rc=$?"

  echo "== 3. 结果目录 =="
  ls -la "/home/qch/scripts/litehost_perf/vllmBench/$TID" 2>&1 | head -10
  find "/home/qch/scripts/litehost_perf/vllmBench/$TID" -name '*.csv' -o -name '*.json' 2>/dev/null | head -10

  echo "== 4. 汇总输出 =="
  head -20 "/home/qch/scripts/litehost_perf/vllmBench/$TID/summary.csv" 2>&1

  echo "== 5. 服务日志尾部 =="
  tail -25 "/home/qch/scripts/litehost_perf/vllmBench/$TID/logs/server.log" 2>&1 | head -30

  echo "== 6. 确认服务已退出 / 显存已释放 =="
  docker exec corex5-py311 bash -c 'pgrep -af vllm | head -5 || echo "no vllm left"' 2>&1
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep 'MiB /' | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
