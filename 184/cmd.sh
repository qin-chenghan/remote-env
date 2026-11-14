#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 检查 4k3 / 64k3 两次 timeline 采集:配置是否一致、服务端有没有告警、trace 是否完整、
# TSHG 对比。纯 CPU,不启动 vllm,不动 GPU。
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
  T=/home/qch/scripts/timeline
  A_ID=4k3
  B_ID=64k3
  A="$T/$A_ID"
  B="$T/$B_ID"

  pick() {
    local d="$1" f
    f=$(find "$d" -type f -name 'rank0*pt.trace.json*' -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    [ -n "$f" ] || f=$(find "$d" -type f \( -name '*.json' -o -name '*.json.gz' \) -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    echo "$f"
  }

  echo "== 0. 机器状态(只能反映当前引导) =="
  uptime -s
  getconf PAGE_SIZE
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null

  echo "== 1. 采集目录 =="
  for d in "$A" "$B"; do
    echo "---- $d"
    ls -ld --time-style=long-iso "$d" 2>/dev/null || echo "缺目录"
    du -sh "$d" 2>/dev/null
    find "$d" -maxdepth 4 -type f -printf '%10s  %TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort -k4
  done

  echo "== 2. 是否用的是新脚本(run_env.txt) =="
  for d in "$A" "$B"; do
    echo "---- $d/run_env.txt"
    cat "$d/run_env.txt" 2>/dev/null || echo "缺 run_env.txt —— 脚本不是新版"
  done
  echo "---- 两份 run_env 的差异(应只有 TEST_ID)"
  if [ -f "$A/run_env.txt" ] && [ -f "$B/run_env.txt" ]; then
    diff "$A/run_env.txt" "$B/run_env.txt"
  fi

  echo "== 3. server.log 关键行 =="
  for d in "$A" "$B"; do
    s="$d/logs/server.log"
    echo "---- $s"
    [ -f "$s" ] || { echo "缺 server.log"; continue; }
    echo "  行数: $(wc -l < "$s")   大小: $(du -h "$s" | cut -f1)"
    echo "  profiler 生效:   $(grep -cE 'Torch profiling enabled|Profiler with mode' "$s")"
    echo "  Unknown env var: $(grep -c 'Unknown vLLM environment variable' "$s")"
    echo "  报错行:          $(grep -cE 'ERROR|Traceback|OutOfMemory|CUDA error|RuntimeError' "$s")"
    grep -nE 'Unknown vLLM environment variable|ERROR|Traceback|OutOfMemory|CUDA error|RuntimeError' "$s" | head -10
    echo "  --- host-opt / cudagraph 相关 ---"
    grep -niE 'host_opt|host-opt|compact_greedy|capturing|graph' "$s" | head -12
    echo "  --- 末尾 15 行 ---"
    tail -15 "$s"
  done

  echo "== 4. bench 结果 =="
  for d in "$A" "$B"; do
    for f in "$d"/logs/bench_instance*.log; do
      [ -f "$f" ] || continue
      echo "---- $f"
      grep -iE 'Successful requests|Benchmark duration|Request throughput|Output token throughput|Mean TTFT|Mean TPOT|Mean ITL' "$f" | head -10
      grep -iE 'error|exception|traceback' "$f" | head -5
    done
  done

  echo "== 5. trace 文件 =="
  FA=$(pick "$A"); FB=$(pick "$B")
  echo "A=$FA"
  ls -l --time-style=long-iso "$FA" 2>/dev/null
  echo "B=$FB"
  ls -l --time-style=long-iso "$FB" 2>/dev/null
  if [ -z "$FA" ] || [ -z "$FB" ]; then echo "缺 trace,后面跳过"; set +x; exit 0; fi

  echo "== 6. TSHG 对比(warmup 0 / 1) =="
  TSHG_WARMUP=0,1 python3 "$DIR/trace_tshg_split.py" "$FA" "$FB" "$A_ID" "$B_ID"
  echo "== 6 结束 exit=$? =="

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
