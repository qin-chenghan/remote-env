#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 184 101902 失败 case 与历史对比：同类 case 正常耗时、window.json 失败原因、驱动检查逻辑、启动 env。
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
  dex() { timeout 150 docker exec "$C" bash -c "$1"; }

  echo "== 1. 历史 run 的 bs8_in2048_out1024 耗时 =="
  dex "for f in /usr/local/corex-5.0.0/vllmBench/*/summary.csv /home/z30059427/vllmBench/*/summary.csv; do [ -f \"\$f\" ] || continue; echo \"-- \$f\"; grep -h 'bs8_in2048_out1024' \"\$f\"; done | tail -30"

  echo "== 2. 失败 case 的 window.json 全文 =="
  dex "cat $P/litehost/bs8_in2048_out1024/window.json"

  echo "== 3. 失败 case 的 case.json 尾段（看 status/acks 是否齐全）=="
  dex "tail -c 700 $P/litehost/bs8_in2048_out1024/case.json; echo"

  echo "== 4. bench_driver 的判定逻辑 =="
  dex "sed -n '30,95p' /home/huawei_ts_program/litehost_perf_opt/bench_driver.py"

  echo "== 5. 启动脚本里的相关 env =="
  dex "grep -nE 'VLLM_|COMPACT|HOST_OPT|export ' /home/*/litehost_perf*/vllmBench_lite*.sh 2>/dev/null | head -30"

  echo "== 6. 本次失败 case 前后时间线（bench 日志时间戳）=="
  dex "ls -l --time-style=full-iso $P/logs/bench_bs8_in2048_out1024.log $P/logs/bench_bs8_in2048_out128.log; stat -c '%y %n' $P/litehost/bs8_in2048_out1024/window.json"

  echo "== 7. 该 case 是否有超时相关配置 =="
  dex "grep -nE 'timeout|TIMEOUT' /home/huawei_ts_program/litehost_perf_opt/bench_driver.py /home/huawei_ts_program/litehost_perf_opt/lhctl.py 2>/dev/null | head -20"

  echo "== 8. 前几次 run 里 2048/1024 是否也有失败痕迹 =="
  dex "grep -rIl 'Formal requests incomplete' /usr/local/corex-5.0.0/vllmBench/*/logs/ 2>/dev/null | head -10"

  echo "== 9. 当前 GPU 空闲与正在跑的任务 =="
  /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'MiB /' | head -4
  docker exec $C bash -c 'ps -eo pid,etime,args | grep -E "vllm|bench_driver" | grep -v grep | head -5' 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
