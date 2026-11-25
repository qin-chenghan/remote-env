#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
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
  echo "### 本轮全部只读：不写、不删、不动 /home/qch/9case"
  set +x

  # ---- 命令开始 ----
  echo "== 0. 定位 9case 运行目录 =="
  ls -dt /home/qch/9case/vllmBench/vllmBase_9case_* 2>/dev/null | head -5
  RUN="$(ls -dt /home/qch/9case/vllmBench/vllmBase_9case_* 2>/dev/null | head -1)"
  if [[ -z "$RUN" ]]; then
    echo "!! /home/qch/9case/vllmBench 下没有 vllmBase_9case_*，全局回退搜索"
    RUN="$(find /home/qch -maxdepth 4 -type d -name 'vllmBase_9case_*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  fi
  echo "RUN=${RUN:-<none>}"
  echo "-- 9case 根目录 --"
  ls -la /home/qch/9case 2>&1 | head -15
  echo "-- DONE/FAILED 标志 --"
  ls -l /home/qch/9case/*DONE* /home/qch/9case/*FAILED* 2>/dev/null || echo "无标志文件"
  echo "-- 容器内 9case shell 是否还在跑 --"
  pgrep -af 'vllmBench_lite_base.sh|vllm.entrypoints.openai.api_server|bench_driver.py' | head -8 || echo "无残留进程"

  if [[ -z "$RUN" ]]; then
    echo "== 未找到运行目录，检查到此为止 =="
  else
    echo
    echo "== 1. 目录与完整性 =="
    ls -l "$RUN" | sed -n '1,45p'
    echo "-- 期望 9 个 case json --"
    for c in 128_128 128_1024 128_2048 1024_128 1024_1024 1024_2048 2048_128 2048_1024 2048_2048; do
      f="$RUN/bs8_in${c}.json"
      [[ -f "$f" ]] && printf 'OK   %-24s %8s bytes  %s\n' "$(basename "$f")" "$(stat -c%s "$f")" "$(stat -c%y "$f" | cut -d. -f1)" \
                     || printf 'MISS %-24s\n' "$(basename "$f")"
    done
    echo "-- litehost 各 case 目录 --"
    for d in "$RUN"/litehost/bs8_in*_out*/; do
      [[ -d "$d" ]] && printf '%-26s files=%-6s size=%s\n' "$(basename "$d")" "$(find "$d" -type f | wc -l)" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    done
    echo "-- host_summary --"
    ls -l "$RUN/host_summary" 2>&1 | head -12
    echo "-- 核心文件 --"
    ls -l "$RUN/summary.csv" "$RUN/session.json" "$RUN/config.txt" 2>&1

    echo
    echo "== 2. summary.csv（lite 侧逐 case）=="
    if [[ -f "$RUN/summary.csv" ]]; then
      echo "rows(incl header)=$(wc -l < "$RUN/summary.csv")"
      echo "-- 列名 --"
      head -1 "$RUN/summary.csv" | tr ',' '\n' | nl -ba | sed -n '1,80p'
      echo "-- 数据行 --"
      sed -n '2,12p' "$RUN/summary.csv"
    else
      echo "!! 缺 summary.csv"
    fi

    echo
    echo "== 3. client 侧逐 case 指标（json 抽取）=="
    for f in "$RUN"/bs8_in*_out*.json; do
      [[ -f "$f" ]] || continue
      printf '%-24s ' "$(basename "$f" .json)"
      grep -oE '"(duration|completed|total_input_tokens|total_output_tokens|request_throughput|output_throughput|mean_ttft_ms|median_ttft_ms|mean_tpot_ms|median_tpot_ms|p99_ttft_ms|p99_tpot_ms|max_concurrency)"[[:space:]]*:[[:space:]]*[-0-9.eE+]+' "$f" | tr '\n' ' '
      echo
    done

    echo
    echo "== 4. host_summary/report.txt =="
    sed -n '1,140p' "$RUN/host_summary/report.txt" 2>&1

    echo
    echo "== 5. 错误扫描 =="
    echo "-- logs 含 Traceback/OOM/CUDA error 的文件 --"
    grep -rlE 'Traceback|out of memory|CUDA error|RuntimeError|Engine core' "$RUN/logs" 2>/dev/null | sed "s#^$RUN/##" | sort | head -20 || echo "无"
    echo "-- 每个 bench 日志最后 3 行 --"
    for f in "$RUN"/logs/bench_bs8_in*_out*.log; do
      [[ -f "$f" ]] || continue
      printf '### %s\n' "$(basename "$f")"
      tail -n 3 "$f"
    done
    echo "-- server.log 关键模式计数 --"
    for pat in 'Traceback' 'out of memory' 'CUDA error' 'Engine core' 'died' 'ERROR' 'timed out'; do
      printf '%-16s %s\n' "$pat" "$(grep -cE "$pat" "$RUN/logs/server.log" 2>/dev/null || echo 0)"
    done
    echo "-- server.log 末尾 25 行 --"
    tail -n 25 "$RUN/logs/server.log" 2>&1

    echo
    echo "== 6. 运行配置 =="
    sed -n '1,30p' "$RUN/config.txt" 2>&1
    echo "-- session.json --"
    sed -n '1,25p' "$RUN/session.json" 2>&1
    echo "-- base 确认：不应出现 compact_greedy / sample_logits_cudagraph --"
    grep -o 'compact_greedy\|sample_logits_cudagraph' "$RUN/config.txt" "$RUN/logs/server.log" 2>/dev/null | head -5 || true

    echo
    echo "== 7. 空间与收尾 =="
    du -sh "$RUN" 2>/dev/null
    df -h /home | tail -1
  fi
  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
