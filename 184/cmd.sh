#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 核对 litehost 那两次(4K/64K)采集时真正生效的 server 配置:
# compact_greedy / sample_logits_cudagraph / prefix caching / host-opt 是否两边一致。
# 纯 CPU,不启动 vllm,不动 GPU。
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
  V=/home/huawei_ts_program/litehost_perf_opt/vllmBench

  echo "== 0. vllmBench 下所有 run 目录 =="
  find "$V" -maxdepth 1 -mindepth 1 -type d -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort

  echo "== 1. 每个 run 的 server.log 时间范围 =="
  find "$V" -maxdepth 3 -name server.log -printf '%TY-%Tm-%Td %TH:%TM %10s  %p\n' 2>/dev/null | sort

  echo "== 2. 逐 run:真正生效的配置(来自 server.log 的 non-default args) =="
  for d in "$V"/*; do
    s="$d/logs/server.log"
    [ -f "$s" ] || continue
    echo "-------- $d"
    head -1 "$s" | cut -c1-60
    echo -n "  compact_greedy 出现次数: "; grep -c 'compact_greedy' "$s" 2>/dev/null || true
    echo -n "  VLLM_COMPACT_GREEDY 警告: "; grep -c 'Unknown vLLM environment variable detected: VLLM_COMPACT_GREEDY' "$s" 2>/dev/null || true
    grep -m1 -o "'compact_greedy': [A-Za-z]*" "$s" | sed 's/^/  parsed: /'
    grep -m1 -o "'sample_logits_cudagraph': [A-Za-z]*" "$s" | sed 's/^/  parsed: /'
    grep -m1 -o "'sample_logits_cudagraph_scope': '[a-z_]*'" "$s" | sed 's/^/  parsed: /'
    grep -m1 -o "enable_prefix_caching=[A-Za-z]*" "$s" | sed 's/^/  parsed: /'
    grep -m1 -o "compilation_config={'mode'[^}]*}" "$s" | cut -c1-160 | sed 's/^/  config: /'
  done

  echo "== 3. host-opt 是否两边都真正激活 =="
  for d in "$V"/*; do
    s="$d/logs/server.log"
    [ -f "$s" ] || continue
    echo "---- $d"
    grep -m2 'Host opt modes' "$s" 2>/dev/null | cut -c1-200
  done

  echo "== 4. 每 run 的实测结果 =="
  for d in "$V"/*; do
    [ -d "$d" ] || continue
    echo "---- $d"
    ls -l --time-style=long-iso "$d"/*.json 2>/dev/null | head -3
    for f in "$d"/summary.csv; do
      [ -f "$f" ] && { echo "  ## $f"; head -3 "$f"; }
    done
    for f in $(find "$d" -maxdepth 3 -name 'four_rank_totals.csv' 2>/dev/null | head -1); do
      echo "  ## $f"; head -1 "$f"; grep -m1 'in128_out128' "$f"
    done
    for f in $(find "$d" -maxdepth 3 -name 'per_rank.csv' 2>/dev/null | head -1); do
      echo "  ## $f"; head -1 "$f"; grep -m1 'in128_out128' "$f"
    done
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
