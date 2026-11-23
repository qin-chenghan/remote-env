#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：一次跑完剩余 6 个 case（verbose），验证缓存是否已全覆盖（零编译）。
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
TEST_ID=prime_py312_rest6
LOG=/tmp/run_${TEST_ID}.log
CASES=/tmp/cases_rest6.txt

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

  echo "== 2. 启动剩余 6 case（CASE_INTERVAL=0, verbose）=="
  docker exec "$C" bash -lc "cat > $CASES <<EOF
128 1024
128 2048
1024 128
1024 2048
2048 128
2048 1024
EOF
cat $CASES"
  docker exec -d "$C" bash -lc "cd $TOOLS && \
    CASES_FILE=$CASES TEST_ID=$TEST_ID HOST_MEASURE=off MODEL_PATH=$MODEL \
    CASE_INTERVAL=0 TORCHDYNAMO_VERBOSE=1 \
    nohup bash vllmBench_lite_base_mock_py312.sh > $LOG 2>&1"
  sleep 30
  docker exec "$C" bash -lc "grep -E 'PREFIX=|inductor_cache=|CASES:' $LOG | head -3; tail -2 $LOG"

  echo "== 3. 等待完成（最多 20 分钟）=="
  for i in $(seq 1 40); do
    if docker exec "$C" test -f "$TOOLS/vllmBench/$TEST_ID/summary.csv" 2>/dev/null; then
      echo "summary.csv 已生成"; break
    fi
    [ "$i" -eq 1 ] && echo "等待中（30s/轮）"
    sleep 30
  done

  echo "== 4. 各 case 结果 =="
  docker exec "$C" bash -lc "cut -d, -f2,4,6,8,11 $TOOLS/vllmBench/$TEST_ID/summary.csv 2>/dev/null"

  echo "== 5. 零编译验证 =="
  docker exec "$C" bash -lc "echo \"Compiling lines: \$(grep -c 'Compiling' $TOOLS/vllmBench/$TEST_ID/logs/server.log 2>/dev/null || echo 0)\""
  docker exec "$C" bash -lc "echo \"cache after=\$(find $CACHE -name '*.py' | wc -l)\"; du -sh $CACHE 2>/dev/null"

  echo "== 6. 残留 =="
  docker exec "$C" bash -lc 'pgrep -af "vllm[.]entrypoints|bench_driver" | grep -v pgrep || echo none'
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "ports free"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
