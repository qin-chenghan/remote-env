#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：用 py312 跑 2048/2048 预热并带 verbose 验证零编译。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
TOOLS=/home/huawei_ts_program/litehost_perf_opt
MODEL=/home/model/Qwen3-32B-W8A8
CACHE=/home/huawei_ts_program/inductor_cache_py312
TEST_ID=prime_py312_2048
LOG=/tmp/run_${TEST_ID}.log
CASES=/tmp/cases_2048.txt

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 空闲检查 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm[.]entrypoints[.]openai[.]api_server|bench_driver" | grep -v pgrep || echo "no server/bench"'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 free"
  if docker exec "$C" bash -lc 'pgrep -f "vllm[.]entrypoints[.]openai[.]api_server" >/dev/null 2>&1'; then
    echo "!! 有服务在跑，退出"; exit 5
  fi
  docker exec "$C" bash -lc "echo \"cache before=\$(find $CACHE -name '*.py' | wc -l)\""

  echo "== 2. 启动 2048/2048 预热（verbose）=="
  docker exec "$C" bash -lc "printf '2048 2048\n' > $CASES; cat $CASES"
  docker exec -d "$C" bash -lc "cd $TOOLS && \
    CASES_FILE=$CASES TEST_ID=$TEST_ID HOST_MEASURE=off MODEL_PATH=$MODEL \
    TORCHDYNAMO_VERBOSE=1 \
    nohup bash vllmBench_lite_base_mock_py312.sh > $LOG 2>&1"
  sleep 30
  docker exec "$C" bash -lc "grep -E 'PREFIX=|inductor_cache=' $LOG | head -2; tail -2 $LOG"

  echo "== 3. 等待完成（最多 15 分钟）=="
  for i in $(seq 1 30); do
    if docker exec "$C" test -f "$TOOLS/vllmBench/$TEST_ID/summary.csv" 2>/dev/null; then
      echo "summary.csv 已生成"; break
    fi
    [ "$i" -eq 1 ] && echo "等待中（30s/轮）"
    sleep 30
  done

  echo "== 4. 结果 =="
  docker exec "$C" bash -lc "tail -6 $LOG"
  docker exec "$C" bash -lc "cut -d, -f2,4,5,6,8,11 $TOOLS/vllmBench/$TEST_ID/summary.csv 2>/dev/null"

  echo "== 5. 零编译验证 =="
  docker exec "$C" bash -lc "echo \"Compiling lines: \$(grep -c 'Compiling' $TOOLS/vllmBench/$TEST_ID/logs/server.log 2>/dev/null || echo 0)\""
  docker exec "$C" bash -lc "echo \"cache after=\$(find $CACHE -name '*.py' | wc -l)\""
  docker exec "$C" bash -lc "du -sh $CACHE 2>/dev/null"

  echo "== 6. 残留 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm[.]entrypoints|bench_driver" | grep -v pgrep || echo none'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "ports free"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
