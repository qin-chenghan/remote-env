#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：跑绑核版 lite bench——TP0..3 各占一核，CPU0 留给外部采样器。
#       容器已存在且带 SYS_NICE 时不重建。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

CONTAINER=corex5-py311-mock
IMAGE=corex5-py311:py3116-20261029
TOOLS=/home/huawei_ts_program/litehost_perf_opt
MODEL=/home/model/Qwen3-32B-W8A8
MOCK=/home/qch/mock_vllm
TEST_ID="pin145_$(date +%H%M)"

# CPU0 留给采样器；TP0..3 各一核；服务进程只在 1-63 里调度
CPU_RANGE="${CPU_RANGE:-1-63}"
TP_CPUS="${MOCK_TP_CPUS:-2,3,4,5}"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 容器状态（存在就复用，不重建）=="
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    docker ps -a --filter "name=$CONTAINER" --format '{{.Names}} {{.Status}}'
    docker inspect "$CONTAINER" \
      --format 'CapAdd={{.HostConfig.CapAdd}} SecurityOpt={{.HostConfig.SecurityOpt}} Pid={{.HostConfig.PidMode}}'
    docker start "$CONTAINER" >/dev/null 2>&1 || true
  else
    echo "-- 容器不存在，按标准参数创建 --"
    docker run -d --name "$CONTAINER" --network host \
      --security-opt label=disable --cap-add SYS_NICE \
      -v /home:/home "$IMAGE" sleep infinity || exit 1
    sleep 3
  fi
  docker ps --filter "name=$CONTAINER" --format '{{.Names}} {{.Status}}'

  echo "== 2. 代码与前置检查 =="
  grep -q "def _pin_worker" "$MOCK/mock_gpu/worker_patch.py" \
    || { echo "!! mock 代码里没有 _pin_worker，先在 /home/qch/tools/remote-env 里 git pull"; exit 3; }
  [ -f "$TOOLS/vllmBench_lite_base_mock.sh" ] || { echo "!! 缺 harness"; exit 3; }
  [ -f "$MODEL/config.json" ] || { echo "!! 缺模型"; exit 3; }
  if ss -ltn 2>/dev/null | grep -q ':8948 '; then
    echo "!! 8948 被占用，先停掉在跑的服务"; exit 5
  fi
  echo "CPU_RANGE=$CPU_RANGE  MOCK_TP_CPUS=$TP_CPUS"

  echo "== 3. 启动绑核 bench（后台）=="
  echo "TEST_ID=$TEST_ID"
  docker exec -d "$CONTAINER" bash -lc "cd $TOOLS && \
    MODEL_PATH=$MODEL TEST_ID=$TEST_ID HOST_MEASURE=lite \
    CPU_RANGE=$CPU_RANGE MOCK_TP_CPUS=$TP_CPUS \
    nohup bash vllmBench_lite_base_mock.sh \
    > /home/qch/transfer/run_$TEST_ID.log 2>&1"
  sleep 30
  echo "-- 启动日志（应出现四行 pinned）--"
  grep -E "pinned to cpu|activated|ERROR" "/home/qch/transfer/run_$TEST_ID.log" 2>/dev/null | head -10
  tail -4 "/home/qch/transfer/run_$TEST_ID.log" 2>/dev/null

  echo "== 4. 后续 =="
  echo "日志：/home/qch/transfer/run_$TEST_ID.log"
  echo "结果：$TOOLS/vllmBench/$TEST_ID/host_summary/report.txt"
  echo "采样器请自行 taskset -c 0 绑到 0 号核"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
