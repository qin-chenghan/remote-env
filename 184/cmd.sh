#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 补上 off 分支缺失的 PGO tcmalloc，重装并验证。
# 纯 CPU，不启动 vllm，不动 GPU。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TARGET=/home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh
CTR=corex5-py311

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

  echo "== 1. start_server 的环境注入段 =="
  sed -n '/^start_server() {/,/^}/p' "$TARGET" | sed -n '1,40p' | cat -n

  echo "== 2. tcmalloc 库是否可见 =="
  docker exec "$CTR" ls -l /home/lw/gperftools/.libs/libtcmalloc.so 2>&1

  echo "== 3. 容器内 dry-run =="
  docker exec "$CTR" bash -lc "cd /tmp && HOST_DRY_RUN=1 TEST_ID=dryrun_$TS bash $TARGET"
  echo "  (dry-run exit=$?)"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
