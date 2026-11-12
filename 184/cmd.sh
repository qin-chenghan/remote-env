#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 检查 150257 这次 9-case 跑的每个 case 是否有效，以及聚合层为什么缺失。
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
  P=/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261112_150257

  echo "== 1. 顶层目录结构（含时间）=="
  docker exec "$C" bash -c "ls -la --time-style=full-iso $P"
  docker exec "$C" bash -c "ls -la --time-style=full-iso $P/litehost"

  echo "== 2. 每个 case 的 four_rank_totals（T/S/H/G）=="
  for case_dir in bs8_in128_out128 bs8_in128_out1024 bs8_in128_out2048 \
                  bs8_in1024_out128 bs8_in1024_out1024 bs8_in1024_out2048 \
                  bs8_in2048_out128 bs8_in2048_out1024 bs8_in2048_out2048; do
    echo "--- $case_dir ---"
    docker exec "$C" bash -c "cat $P/litehost/$case_dir/host_report/four_rank_totals.csv 2>&1 | head -8"
  done

  echo "== 3. 每个 case 的日志结尾（是否正常收尾）=="
  for case_dir in bs8_in128_out128 bs8_in1024_out1024 bs8_in2048_out2048; do
    f="$P/logs/bench_$case_dir.log"
    echo "--- $f ---"
    docker exec "$C" bash -c "tail -n 15 '$f' 2>&1"
  done

  echo "== 4. 每个 case 的 JSON 结果（吞吐/TTFT）=="
  for case_dir in bs8_in128_out128 bs8_in1024_out1024 bs8_in2048_out2048; do
    echo "--- $case_dir ---"
    docker exec "$C" bash -c "head -c 700 $P/$case_dir.json 2>&1"
    echo
  done

  echo "== 5. server.log 结尾（死因线索）=="
  docker exec "$C" bash -c "tail -n 40 $P/logs/server.log 2>&1"

  echo "== 6. server.log 里的错误关键字 =="
  docker exec "$C" bash -c "grep -n -E 'Traceback|Error|error|Exception|Killed|OOM|abort' $P/logs/server.log 2>&1 | tail -20"

  echo "== 7. 容器里是否还有进程在跑 =="
  docker exec "$C" bash -c "ps -eo pid,etime,args | grep -E 'vllm|benchmark|lhctl' | grep -v grep | head -20"

  echo "== 8. 哪个脚本写的这个路径 =="
  docker exec "$C" bash -c "grep -rl '/usr/local/corex-5.0.0/vllmBench' /home /usr/local/bin /opt 2>/dev/null --include='*.sh' --include='*.py' | head -20"
  docker exec "$C" bash -c "ps -eo args | grep -E 'vllmBench_lite|bench_driver|vllm' | grep -v grep | head -5"

  echo "== 9. 最近的脚本修改时间 =="
  docker exec "$C" bash -c "ls -lat --time-style=full-iso /home/huawei_ts_program/litehost_perf_opt/*.sh 2>/dev/null | head -6"
  docker exec "$C" bash -c "ls -lat --time-style=full-iso /home/s00806700/litehost_perf_opt/*.sh 2>/dev/null | head -6"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
