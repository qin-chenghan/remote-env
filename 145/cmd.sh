#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。核对最新一轮预热 run：配置、启动耗时、缓存目录、绑核审计。
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

  echo "== 1. 最近三轮 run =="
  D "ls -1dt /home/huawei_ts_program/litehost_perf_opt/vllmBench/*/ | head -3"

  echo "== 2. 最新 run 的 config =="
  D 'P=$(ls -1dt /home/huawei_ts_program/litehost_perf_opt/vllmBench/*/ | head -1); echo "P=$P"
     cat "$P/config.txt" 2>/dev/null | head -40'

  echo "== 3. harness 日志的关键行 =="
  D 'P=$(ls -1dt /home/huawei_ts_program/litehost_perf_opt/vllmBench/*/ | head -1)
     grep -nE "host_tag=|inductor_cache=|预热完成|PCH 新增|绑核|warmup_only|FATAL|退出码" "$P"/run.log 2>/dev/null | head -20
     ls "$P" 2>/dev/null'

  echo "== 4. server.log 启动时间线与关键行 =="
  D 'P=$(ls -1dt /home/huawei_ts_program/litehost_perf_opt/vllmBench/*/ | head -1)
     L="$P/logs/server.log"
     ls -l "$L" 2>/dev/null
     grep -nE "mock_gpu\]|loading took|Capturing CUDA graphs|startup complete|pinned to cpu|Cpus_allowed|died unexpectedly|RuntimeError|Traceback|SIGSEGV|SIGILL" "$L" 2>/dev/null | head -30
     echo "-- 首末时间"; head -3 "$L" 2>/dev/null; tail -5 "$L" 2>/dev/null'

  echo "== 5. capture 进度（tqdm 最后几个快照）=="
  D 'P=$(ls -1dt /home/huawei_ts_program/litehost_perf_opt/vllmBench/*/ | head -1)
     tr "\r" "\n" < "$P/logs/server.log" 2>/dev/null | grep -oE "Capturing CUDA graphs[^|]*\| *[0-9]+/[0-9]+" | tail -5
     tr "\r" "\n" < "$P/logs/server.log" 2>/dev/null | grep -oE "Adding requests: *[0-9]+%" | tail -3'

  echo "== 6. 缓存现状 =="
  D 'C=/home/huawei_ts_program/inductor_cache_py312
     ls -1d $C $C/h-* 2>/dev/null
     for d in $C/h-*; do echo "$d: so=$(find $d -name "*.so" 2>/dev/null | wc -l) py=$(find $d -name "*.py" 2>/dev/null | wc -l)"; done
     echo "-- 最新 .so"; find $C -name "*.so" -newermt "2026-11-25 00:00" -printf "%TH:%TM %s %p\n" 2>/dev/null | sort | tail -6
     echo "-- PCH"; ls -la --time-style=long-iso /tmp/torchinductor_root/precompiled_headers/*.gch 2>/dev/null'

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
