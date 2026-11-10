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
  echo "== container config env =="
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' corex5-py311 2>&1 | grep -E 'PYTHON|LD_|PATH='

  echo "== tcmalloc search =="
  find /home -maxdepth 5 -name 'libtcmalloc.so*' 2>/dev/null | head -5
  find /usr/local /opt -maxdepth 5 -name 'libtcmalloc.so*' 2>/dev/null | head -5

  echo "== server launch block (base) =="
  sed -n '/SERVER_EXTRA_ENV/,/SERVER_PID/p' /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base.sh 2>&1 | head -70

  echo "== server launch block (opt) =="
  sed -n '/SERVER_EXTRA_ENV/,/SERVER_PID/p' /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh 2>&1 | head -70

  echo "== LD_PRELOAD assembly =="
  grep -n 'LD_PRELOAD\|CLEAN_ENV\|LIGHTHOST' /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base.sh \
    /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh 2>&1 | head -30

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
