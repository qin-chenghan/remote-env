#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。把两次失败轮的 server.log 全文拉回来（各约 50 KB），
#       看 09:53→10:38 那 45 分钟到底卡在哪一步。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
CT=vllm

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE")
D() { printf '%s\n' "$1" | "${SSH[@]}" "docker exec -i $CT bash -s" 2>&1 | sed '/^Authorized users only/d'; }

{
  echo "### server: 145 -> 198 vllm 容器  (只读)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  echo "== 093806 完整 server.log =="
  D 'L=/home/huawei_ts_program/litehost_perf_opt/vllmBench/py312_litehost_gap_20261125_093806/logs/server.log
     wc -lc "$L"; tr "\r" "\n" < "$L" | grep -vE "Capturing CUDA graphs" | head -700'

  echo "== 093806 harness 侧 =="
  D 'P=/home/huawei_ts_program/litehost_perf_opt/vllmBench/py312_litehost_gap_20261125_093806
     ls -la "$P" "$P/control" 2>/dev/null | head -20
     for f in "$P"/control/*; do echo "--- $f"; head -40 "$f"; done 2>/dev/null'

  echo "== 100823 完整 server.log =="
  D 'L=/home/huawei_ts_program/litehost_perf_opt/vllmBench/py312_litehost_gap_20261124_100823/logs/server.log
     wc -lc "$L"; tr "\r" "\n" < "$L" | grep -vE "Capturing CUDA graphs" | head -700'

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
