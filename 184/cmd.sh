#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 小验证：单 case 2048/1024、16 prompts、HOST_MEASURE=off，同时抓 dmesg，看 export_refcount 是否由 vLLM 触发。
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
  C=corex5-py311
  D=/home/huawei_ts_program/litehost_perf_opt
  TID=probe_$(date +%H%M%S)
  BASE_N=$(dmesg 2>/dev/null | grep -c 'export_refcount')

  echo "== 1. 前置检查 =="
  uname -r
  BUSY=$(docker exec $C bash -c 'ps -eo args | grep -E "vllm|bench_driver" | grep -v grep | head -3')
  if [ -n "$BUSY" ]; then echo "BUSY:"; echo "$BUSY"; echo "有服务在跑，终止"; exit 4; fi
  echo "无 vllm/bench 进程"
  /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'MiB /' | head -4
  echo "dmesg 中 export_refcount 基线计数: $BASE_N"

  echo "== 2. 启动 dmesg 采集 =="
  dmesg -T -w > "/tmp/dmesg-$TS.log" 2>&1 &
  DPID=$!
  trap 'kill "$DPID" 2>/dev/null' EXIT
  sleep 1
  echo "dmesg watcher pid=$DPID"

  echo "== 3. 单 case 运行（不等同于全量，仅用于对照告警）=="
  timeout 900 docker exec \
    -e NUM_PROMPTS=16 -e NUM_WARMUPS=4 -e CASE_INTERVAL=0 -e HOST_MEASURE=off \
    -e TEST_ID="$TID" -e CASES_FILE=/tmp/cases_probe.txt \
    "$C" bash -lc "printf '2048 1024\n' > /tmp/cases_probe.txt && cd $D && bash vllmBench_lite_opt.sh" 2>&1 | tail -40
  echo "run rc=$?"

  echo "== 4. 结果 =="
  R=/usr/local/corex-5.0.0/vllmBench/$TID
  docker exec "$C" bash -c "ls -l $R 2>/dev/null | head -8; echo '--- summary ---'; head -3 $R/summary.csv 2>/dev/null" 2>&1
  docker exec "$C" bash -c "echo '--- window ---'; cat $R/litehost/*/window.json 2>/dev/null | head -c 900" 2>&1

  echo "== 5. 告警对照 =="
  sleep 1
  kill "$DPID" 2>/dev/null
  trap - EXIT
  echo "--- 本次窗口内的 export_refcount ---"
  grep -c 'export_refcount' "/tmp/dmesg-$TS.log" 2>/dev/null
  grep 'export_refcount' "/tmp/dmesg-$TS.log" 2>/dev/null | head -10
  echo "--- 其他 iluvatar 消息 ---"
  grep -iE 'iluvatar|gpu|export|refcount' "/tmp/dmesg-$TS.log" 2>/dev/null | tail -15
  echo "--- 运行前后计数对比 ---"
  echo "before=$BASE_N after=$(dmesg 2>/dev/null | grep -c 'export_refcount')"

  echo "== 6. 收尾 =="
  docker exec "$C" bash -c 'ps -eo pid,args | grep -E "vllm|bench_driver" | grep -v grep | head -3 || echo none' 2>&1
  /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'MiB /' | head -4

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
