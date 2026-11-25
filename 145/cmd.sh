#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。对比成功/失败各轮的环境差异（尤其是 MOCK_TP_CPUS 与绑核）。
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

  echo "== 1. 各轮 config 对比（成功 vs 失败）=="
  D 'V=/home/huawei_ts_program/litehost_perf_opt/vllmBench
     for d in py312_warmup_20261125 test-warmup1 test-warmup2 py312_litehost_gap_20261125_093806 py312_litehost_gap_20261124_100823; do
       echo "##### $d"
       grep -hE "^(started|host_tag|mock_env|warmup_only|stall_guard|cpu_range)=" "$V/$d/config.txt" 2>/dev/null
     done'

  echo "== 2. 失败轮的服务器日志时间线 =="
  D 'V=/home/huawei_ts_program/litehost_perf_opt/vllmBench
     for d in py312_litehost_gap_20261125_093806 py312_litehost_gap_20261124_100823; do
       echo "##### $d"
       L="$V/$d/logs/server.log"
       [ -f "$L" ] && stat -c "%y %s %n" "$L"
       grep -nE "runner ready|Capturing CUDA graphs|died unexpectedly|RuntimeError|pinned to cpu" "$L" 2>/dev/null | head -8
       tr "\r" "\n" < "$L" 2>/dev/null | grep -oE "\| *[0-9]+/35" | tail -2
     done'

  echo "== 3. 成功轮的关键时间点（预热总耗时）=="
  D 'P=/home/huawei_ts_program/litehost_perf_opt/vllmBench/py312_warmup_20261125
     L="$P/logs/server.log"
     grep -nE "runner ready|Capturing CUDA graphs|route|Started server|Application startup|ready" "$L" 2>/dev/null | head -10
     echo "-- 文件时间线"; ls -la --time-style=long-iso "$P" "$P/logs" 2>/dev/null
     echo "-- 新 .so 时间"; find /home/huawei_ts_program/inductor_cache_py312/h-* -name "*.so" -printf "%TH:%TM:%TS %s %f\n" 2>/dev/null | sort'

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
