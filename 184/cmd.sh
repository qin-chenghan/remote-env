#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 184 最新采样 run（容器 corex5-py311 内 /usr/local/.../litehost_gap_20261113_101902）问题排查。
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
  V=/opt/corex311-cpython-vllm
  dex() { timeout 120 docker exec "$C" bash -c "$1"; }

  echo "== 1. 目录结构与体量 =="
  dex "ls -lat $P; echo; ls -la $P/logs 2>/dev/null | head -20; echo; du -sh $P 2>/dev/null; find $P -type f | wc -l"

  echo "== 2. 关键文件是否齐全 =="
  dex "for f in summary.csv session.json config.txt preflight.log; do ls -l $P/\$f 2>&1; done"
  dex "ls -d $P/host_summary 2>&1; ls $P/host_summary 2>&1 | head -6"
  dex "ls $P/litehost 2>/dev/null | head -20; echo '--- litehost case 数 ---'; ls -d $P/litehost/*/ 2>/dev/null | wc -l"

  echo "== 3. 是否还在跑 =="
  dex "date; ps -eo pid,etime,args | grep -E 'vllm|bench_driver|lhctl|vllmBench' | grep -v grep | head -10"

  echo "== 4. 日志尾部 =="
  dex "echo '--- server.log ---'; tail -n 40 $P/logs/server.log 2>&1"
  dex "echo '--- summary_build.log ---'; tail -n 20 $P/logs/summary_build.log 2>&1"
  dex "echo '--- preflight.log ---'; cat $P/logs/preflight.log 2>&1 | head -20"

  echo "== 5. bench 日志与 case 结果 =="
  dex "ls -l $P/logs/bench_*.log 2>/dev/null | head -15; echo; ls -l $P/*.json 2>/dev/null | head -15"
  dex "for f in $P/logs/bench_*.log; do [ -f \"\$f\" ] && { echo \"---- \$f\"; tail -n 8 \"\$f\"; }; done 2>&1 | tail -60"

  echo "== 6. 错误关键字扫描 =="
  dex "grep -nE 'ERROR|Traceback|Exception|failed|Failed|Killed|OOM|out of memory|timeout|Timeout|FATAL|abort' $P/logs/*.log 2>/dev/null | tail -40"

  echo "== 7. litehost 会话与采集完整性 =="
  dex "cat $P/session.json 2>/dev/null | head -c 500; echo"
  dex "for d in $P/litehost/*/; do echo -n \"\$d \"; ls \"\$d\" 2>/dev/null | tr '\n' ' '; echo; done 2>&1 | head -20"

  echo "== 8. 容器内空间与 venv =="
  dex "df -h /opt /usr/local 2>/dev/null | tail -3; du -sh /usr/local/corex-5.0.0/vllmBench 2>/dev/null"
  dex "ls -ld $V 2>&1; $V/bin/python -c 'import vllm;print(vllm.__version__)' 2>&1 | tail -2"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
