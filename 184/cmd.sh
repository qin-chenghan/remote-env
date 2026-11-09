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
  # 184 两个脚本的默认 MODEL_PATH 改为 /home/model/Qwen3-32B-W8A8（ts 路径在 184 不存在）。

  D=/home/huawei_ts_program/litehost_perf_opt
  TS2=$(date +%Y%m%d-%H%M%S)

  for f in vllmBench_lite_base.sh vllmBench_lite_opt.sh; do
    echo "== $f =="
    cp -a "$D/$f" "$D/$f.bak-modelpath-$TS2"
    python3 - "$D/$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'MODEL_PATH="${MODEL_PATH:-/home/model/ts/Qwen3-32B-W8A8}"'
new = 'MODEL_PATH="${MODEL_PATH:-/home/model/Qwen3-32B-W8A8}"'
if old not in s:
    raise SystemExit(f"FAIL {p}: MODEL_PATH line not found")
open(p, "w").write(s.replace(old, new, 1))
print("updated", p)
PY
    bash -n "$D/$f" && echo "OK $f"
    grep -n "MODEL_PATH=" "$D/$f" | head -2
  done

  echo "== 容器内 dry-run（base/opt）=="
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= corex5-py311 bash -c \
    "cd $D && HOST_DRY_RUN=1 bash vllmBench_lite_base.sh" 2>&1 | grep -E "PREFIX=|SERVER:|ERROR" | head -2
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= corex5-py311 bash -c \
    "cd $D && HOST_DRY_RUN=1 bash vllmBench_lite_opt.sh" 2>&1 | grep -E "PREFIX=|SERVER:|ERROR" | head -2

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
