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
  # 184 r10 实卡冒烟：单 case 128/128，20 prompts，4 warmups，GPU 0-3，端口 8848。
  # 有 bench/vllm 进程则中止。

  D=/home/huawei_ts_program/litehost_perf_opt
  CASES=/home/qch/transfer/cases_r10_smoke_184.txt
  printf '128 128\n' > "$CASES"

  echo "== 0. 占用检查 =="
  BUSY=$(pgrep -af "vllmBench|bench_driver|vllm.entrypoints|api_server" 2>/dev/null | grep -v "pgrep\|cmd.sh" || true)
  if [ -n "$BUSY" ]; then echo "ABORT: 有任务在跑"; echo "$BUSY" | head -5; exit 1; fi
  echo "无任务"

  echo "== 1. 模型路径 =="
  MP=/home/model/ts/Qwen3-32B-W8A8
  [ -d "$MP" ] || MP=/home/model/Qwen3-32B-W8A8
  echo "MODEL_PATH=$MP"

  echo "== 2. 冒烟前 GPU =="
  timeout 15 /usr/local/corex-5.0.0/bin/ixsmi 2>/dev/null | grep -E "MiB / 32768" | head -4

  echo "== 3. 运行 opt 冒烟 =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= corex5-py311 bash -c \
    "cd $D && CASES_FILE=$CASES NUM_PROMPTS=20 NUM_WARMUPS=4 TEST_ID=r10_smoke_184 PORT=8848 MODEL_PATH=$MP bash vllmBench_lite_opt.sh"
  RC=$?
  echo "smoke rc=$RC"

  echo "== 4. 结果与 r10 证据 =="
  RUN_DIR="$D/vllmBench/r10_smoke_184"
  ls -la "$RUN_DIR" 2>/dev/null | head -10
  echo "-- server.log 证据 --"
  grep -iE "VLLM_HOST_OPT|VLLM_HOST_FASTPATH|HOST_OPT|host_opt|compact_greedy|Sample logits|metadata|COREX_HOST" \
    "$RUN_DIR/logs/server.log" 2>/dev/null | head -20 || echo "(无匹配)"
  echo "-- 结果 json --"
  cat "$RUN_DIR/bs8_in128_out128.json" 2>/dev/null | head -5
  echo "-- summary --"
  cat "$RUN_DIR/summary.csv" 2>/dev/null | head -4

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
