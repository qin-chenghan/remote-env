#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：从 timeline 日志反查实际使用的解释器/vllm 路径（不启动任何服务）。
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
  echo "== 1. timeline 目录结构 =="
  ls -lat --time-style=long-iso /home/qch/scripts/timeline 2>/dev/null | head -10
  for d in 4k 4k2 64k 64k2; do
    echo "---- $d"; ls -l --time-style=long-iso "/home/qch/scripts/timeline/$d/logs" 2>/dev/null | head -6
  done

  echo "== 2. 日志里出现的解释器/依赖路径 =="
  for d in 4k 4k2 64k 64k2; do
    L=/home/qch/scripts/timeline/$d/logs
    [ -d "$L" ] || continue
    echo "===== $d"
    grep -ohE '/opt/cpython-vllm/v1|/opt/corex311-cpython-vllm|/opt/corex311/|/usr/local/lib/python3\.12|python3\.12|python3\.11' "$L"/*.log 2>/dev/null | sort | uniq -c | sort -rn | head -8
  done

  echo "== 3. server.log 开头（看启动路径与 vllm 版本）=="
  for d in 4k 64k; do
    echo "===== $d"
    head -6 "/home/qch/scripts/timeline/$d/logs/server.log" 2>/dev/null | cut -c1-180
    grep -m2 -E 'vllm.*version|Platform plugin' "/home/qch/scripts/timeline/$d/logs/server.log" 2>/dev/null | cut -c1-160
  done

  echo "== 4. 是否出现 host_opt / r14 相关日志 =="
  for d in 4k 64k; do
    echo "===== $d"
    grep -c 'COREX_HOST_OPT\|VLLM_HOST_OPT\|host_opt' "/home/qch/scripts/timeline/$d/logs/server.log" 2>/dev/null
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
