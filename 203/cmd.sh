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
  echo "== 1. GPU 的 NUMA 归属 =="
  for b in 0000:10:00.0 0000:13:00.0 0000:19:00.0 0000:1c:00.0; do
    printf '%s numa_node=%s\n' "$b" "$(cat "/sys/bus/pci/devices/$b/numa_node" 2>/dev/null || echo n/a)"
  done

  echo "== 2. 容器内依赖 =="
  docker exec corex5-py311 bash -lc 'command -v curl || echo NO_CURL; command -v taskset || echo NO_TASKSET' 2>&1

  CURL_OK=$(docker exec corex5-py311 bash -lc 'command -v curl >/dev/null && echo yes || echo no' 2>/dev/null)
  echo "curl_ok=$CURL_OK"
  if [ "$CURL_OK" != "yes" ]; then
    echo "!! 容器内没有 curl，脚本的 wait_for_server 会等满 600s 超时，先不跑。"
  else
    echo "== 3. 基线运行：HOST_MEASURE=off，单 case 128/2048 =="
    TID="baseline_$(date +%H%M%S)"
    timeout 1500 docker exec \
      -e HOST_MEASURE=off \
      -e NUM_PROMPTS=32 \
      -e NUM_WARMUPS=4 \
      -e CASE_INTERVAL=0 \
      -e TEST_ID="$TID" \
      -e CASES_FILE=/tmp/cases_one.txt \
      corex5-py311 bash -lc '
        printf "128 2048\n" > /tmp/cases_one.txt
        cd /home/qch/scripts/litehost_perf && bash vllmBench_lite_base.sh
      ' 2>&1 | tail -50
    echo "run rc=$?"

    R=/home/qch/scripts/litehost_perf/vllmBench/$TID
    echo "== 4. 结果 =="
    ls -la "$R" 2>&1 | head -10
    head -5 "$R/summary.csv" 2>&1
    echo "== 服务日志尾部 =="
    tail -20 "$R/logs/server.log" 2>&1 | head -25
  fi

  echo "== 5. 收尾确认 =="
  docker exec corex5-py311 bash -c 'pgrep -af vllm | head -5 || echo "no vllm left"' 2>&1
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep 'MiB /' | head -5
  df -h / /home | tail -2

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
