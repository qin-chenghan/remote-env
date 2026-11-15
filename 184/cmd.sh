#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 重装修正后的 vllmBench_lite_timeline.sh：停服时给 profiler 落盘留时间
# （procutil.py stop 只等 10s，torch profiler 不够）。
# 纯 CPU，不启动 vllm，不动 GPU。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TARGET=/home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh
REF=/home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh
PREFIX="${PREFIX:-/opt/corex311-cpython-vllm}"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  echo "== 0. 安装（备份） =="
  [ -f "$TARGET" ] && cp -a "$TARGET" "$TARGET.bak-$TS"
  install -m 755 "$DIR/vllmBench_lite_timeline.sh" "$TARGET" || exit 1
  sha256sum "$TARGET"
  bash -n "$TARGET" && echo "bash -n OK"

  echo "== 1. 与 11-14 脚本的完整差异 =="
  diff -u "$REF" "$TARGET"
  echo "  (diff exit=$?)"

  echo "== 2. 停服逻辑（cleanup 段） =="
  sed -n '/^cleanup() {/,/^}/p' "$TARGET" | cat -n

  echo "== 3. PREFIX 可见性 =="
  ls -ld "$PREFIX" 2>&1
  ls -l "$PREFIX/bin/python3" 2>&1

  echo "== 4. dry-run（venv 不可见时跳过，需在容器内执行） =="
  if [ -x "$PREFIX/bin/python3" ]; then
    ( cd /tmp && HOST_DRY_RUN=1 TEST_ID="dryrun_$TS" bash "$TARGET" )
    echo "  (dry-run exit=$?)"
  else
    echo "  SKIP: $PREFIX/bin/python3 不可执行；请在容器内跑:"
    echo "        cd /tmp && HOST_DRY_RUN=1 TEST_ID=dryrun_$TS bash $TARGET"
  fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
