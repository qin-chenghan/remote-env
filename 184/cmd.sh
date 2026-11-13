#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读排查：不跑 vllm、不跑压测，只 cat/grep 已有文件，几秒结束。
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
  P=/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261113_101902
  D=/home/huawei_ts_program/litehost_perf_opt
  dex() { timeout 30 docker exec "$C" bash -c "$1"; }

  echo "== 1. 失败 case 的 window.json 全文 =="
  dex "cat $P/litehost/bs8_in2048_out1024/window.json"

  echo "== 2. case.json 尾段 =="
  dex "tail -c 900 $P/litehost/bs8_in2048_out1024/case.json; echo"

  echo "== 3. bench_driver.py：判定与采集逻辑 =="
  dex "sed -n '1,100p' $D/bench_driver.py"

  echo "== 4. 历史 run 里 bs8_in2048_out1024 的耗时 =="
  dex "for f in /usr/local/corex-5.0.0/vllmBench/*/summary.csv /home/z30059427/vllmBench/*/summary.csv; do [ -f \"\$f\" ] && grep -H 'bs8_in2048_out1024' \"\$f\"; done | tail -20"

  echo "== 5. 启动脚本里的 env 与 case 顺序 =="
  dex "ls -l $D/*.sh 2>/dev/null | head -10"
  dex "grep -nE 'CASES|VLLM_|COMPACT|HOST_OPT|timeout' $D/vllmBench_lite*.sh 2>/dev/null | head -40"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
