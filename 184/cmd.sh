#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 安装对齐后的 vllmBench_lite_timeline.sh 到 /home/qch/scripts/litehost_perf/，
# 保留备份，做语法检查 + dry-run 打印最终启动参数 + 与 11-14 脚本 diff + 看 procutil 停止方式。
# 纯 CPU，不启动 vllm，不动 GPU。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TARGET=/home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh
REF=/home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh
TOOLKIT=/home/huawei_ts_program/litehost_perf_opt

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  echo "== 0. 安装（备份原文件） =="
  if [ -f "$TARGET" ]; then
    cp -a "$TARGET" "$TARGET.bak-$TS" || exit 1
    echo "backup: $TARGET.bak-$TS"
  fi
  install -m 755 "$DIR/vllmBench_lite_timeline.sh" "$TARGET" || exit 1
  stat -c '%n  mtime=%y  size=%s' "$TARGET"
  sha256sum "$TARGET"

  echo "== 1. 语法检查 =="
  bash -n "$TARGET" && echo "bash -n OK"

  echo "== 2. 与 11-14 的 vllmBench_lite_opt.sh 的差异（应只剩 profiler 相关行） =="
  diff -u "$REF" "$TARGET"
  echo "  (diff exit=$?)"

  echo "== 3. dry-run：打印最终 server 参数与 case =="
  ( cd /tmp && HOST_DRY_RUN=1 TEST_ID="dryrun_$TS" bash "$TARGET" )
  echo "  (dry-run exit=$?)"

  echo "== 4. procutil.py 全文（确认 stop 是 TERM 等待还是立即杀） =="
  cat -n "$TOOLKIT/procutil.py"

  echo "== 5. 目标目录与 toolkit 位置 =="
  ls -ld /home/qch/scripts/litehost_perf "$TOOLKIT"
  ls -l /home/qch/scripts/litehost_perf/lhctl.py "$TOOLKIT/lhctl.py" 2>&1

  echo "== 6. 旧 timeline 脚本是否跑过：产物与历史 =="
  echo "-- 6a. timeline 目录（旧脚本产物根：<cwd>/timeline/<TEST_ID>） --"
  find /home /root /opt -maxdepth 6 -type d -name timeline 2>/dev/null | head -50
  echo "-- 6b. profile 目录 --"
  find /home /root /opt -maxdepth 8 -type d -name profile 2>/dev/null | head -50
  echo "-- 6c. trace 文件（按时间） --"
  find /home /root /opt -maxdepth 10 -type f \( -name '*.pt.trace.json*' -o -name '*trace*.json*' -o -name '*.json.gz' \) \
    -printf '%TY-%Tm-%Td %TH:%TM %10s  %p\n' 2>/dev/null | sort | tail -60
  echo "-- 6d. 旧脚本残留的 server.log / bench 日志 --"
  find /home /root /opt -maxdepth 10 -path '*/timeline/*' -type f \
    \( -name 'server.log' -o -name 'bench_*.log' \) \
    -printf '%TY-%Tm-%Td %TH:%TM %10s  %p\n' 2>/dev/null | sort | tail -30
  echo "-- 6e. shell 历史里的调用 --"
  for h in /home/*/.bash_history /root/.bash_history; do
    [ -f "$h" ] || continue
    n=$(grep -c 'vllmBench_lite_timeline' "$h" 2>/dev/null || true)
    printf '  %-40s timeline_calls=%s\n' "$h" "${n:-0}"
    grep -n 'vllmBench_lite_timeline\|TEST_ID=' "$h" 2>/dev/null | tail -10
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
