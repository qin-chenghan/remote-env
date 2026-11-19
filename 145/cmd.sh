#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：安装 mock-only 工具包 → 适配自检 → 后台跑 lite(H/G) bench。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TGZ=/home/qch/transfer/litehost_tools.tgz
TOOLS=/home/huawei_ts_program/litehost_perf_opt
CONTAINER=corex5-py311-mock
MODEL=/home/model/Qwen3-32B-W8A8
MOCK=/home/qch/mock_vllm
TEST_ID="lite145_$(date +%H%M)"
FAIL=0

check() {  # check <描述> <命令>
  if eval "$2" >/dev/null 2>&1; then echo "  OK   $1"; else echo "  FAIL $1"; FAIL=1; fi
}

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 安装 mock-only 工具包 =="
  [ -f "$TGZ" ] || { echo "!! 缺 $TGZ"; exit 3; }
  tar xzf "$TGZ" -C "$TOOLS" || exit 1
  ls "$TOOLS"/vllmBench_lite_*.sh

  echo "== 2. 适配自检 =="
  check "容器在跑"            "docker ps --filter name=$CONTAINER --format '{{.Status}}' | grep -q Up"
  check "模型就位"            "[ -f $MODEL/config.json ]"
  check "mock 目录存在"       "[ -d $MOCK/mock_gpu ]"
  check "mock_ix.so 是 aarch64" "file $MOCK/mock_ix.so | grep -q 'ARM aarch64'"
  check "liblitehost.so 是 aarch64" "file $TOOLS/liblitehost.so | grep -q 'ARM aarch64'"
  check "容器内 py3.11"       "docker exec $CONTAINER /opt/corex311/bin/python3 -V 2>&1 | grep -q 3.11"
  check "容器内 taskset"      "docker exec $CONTAINER command -v taskset"
  check "8948 空闲"           "! ss -ltn | grep -q ':8948 '"
  check "CPU 0-63 在同一个 NUMA node" \
        "[ \"\$(lscpu | awk -F: '/NUMA node0/{print \$2}' | tr -d ' ')\" = '0-63' ]"
  check "harness 里 MOCK_DIR 固定" "grep -q 'MOCK_DIR=/home/qch/mock_vllm' $TOOLS/vllmBench_lite_base_mock.sh"
  if [ "$FAIL" -ne 0 ]; then
    echo "!! 适配检查未通过，不启动 bench"
    exit 6
  fi
  echo "  全部通过"

  echo "== 3. 启动 lite(H/G) bench（后台）=="
  echo "TEST_ID=$TEST_ID"
  docker exec -d "$CONTAINER" bash -lc "cd $TOOLS && \
    MODEL_PATH=$MODEL TEST_ID=$TEST_ID HOST_MEASURE=lite \
    nohup bash vllmBench_lite_base_mock.sh \
    > /home/qch/transfer/run_$TEST_ID.log 2>&1"
  sleep 25
  echo "-- 启动日志 --"
  tail -10 "/home/qch/transfer/run_$TEST_ID.log" 2>/dev/null || echo "(日志未出现)"

  echo "== 4. 后续查看 =="
  echo "日志：/home/qch/transfer/run_$TEST_ID.log"
  echo "结果：$TOOLS/vllmBench/$TEST_ID/host_summary/report.txt"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
