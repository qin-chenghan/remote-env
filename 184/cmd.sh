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
  set -x

  # ---- 命令开始 ----
  # 只读：检查用户手工改过的两个 bench 脚本现状。

  D=/home/huawei_ts_program/litehost_perf_opt

  echo "== 1. 目录与备份 =="
  ls -lt --time-style=long-iso "$D"/vllmBench_lite_base.sh "$D"/vllmBench_lite_opt.sh "$D"/*.bak* 2>/dev/null | head -20

  echo "== 2. 语法检查 =="
  bash -n "$D/vllmBench_lite_base.sh" && echo "OK base" || echo "SYNTAX ERROR base"
  bash -n "$D/vllmBench_lite_opt.sh" && echo "OK opt" || echo "SYNTAX ERROR opt"

  echo "== 3. 残留的 pgo/rebase 引用 =="
  grep -in "pgo\|rebase" "$D/vllmBench_lite_base.sh" "$D/vllmBench_lite_opt.sh" || echo "(无)"

  echo "== 4. base 头部与 PGO 区域 =="
  sed -n '1,35p' "$D/vllmBench_lite_base.sh"
  echo "---- 60-140 ----"
  sed -n '60,140p' "$D/vllmBench_lite_base.sh"

  echo "== 5. opt 头部与 PGO 区域 =="
  sed -n '1,35p' "$D/vllmBench_lite_opt.sh"
  echo "---- 60-140 ----"
  sed -n '60,140p' "$D/vllmBench_lite_opt.sh"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
