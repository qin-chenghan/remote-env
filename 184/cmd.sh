#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 全量保全：把完整 run 目录打包备份到 /home/qch/backup，并完整复制到仓库 export。
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
  RUN=/home/s00806700/litehost_perf_opt/vllmBench/litehost_gap_20261112_145924
  NAME=$(basename "$RUN")
  echo "== 1. 确认没有写进程 =="
  pgrep -af 'vllmBench_lite|bench_driver|lhctl' 2>/dev/null | grep -v cmd.sh | head -5
  echo "(空=无写入)"

  echo "== 2. 原始目录完整性 =="
  [ -d "$RUN" ] && echo "RUN ok" || { echo "RUN MISSING"; exit 3; }
  du -sh "$RUN"
  find "$RUN" -type f -printf '%10s  %p\n' | sort -k2 | head -40
  echo "文件数: $(find "$RUN" -type f | wc -l)"

  echo "== 3. 关键文件 sha256 =="
  for f in summary.csv config.txt host_summary/four_rank_totals.csv host_summary/per_rank.csv host_summary/report.txt logs/server.log; do
    [ -f "$RUN/$f" ] && sha256sum "$RUN/$f"
  done

  echo "== 4. 本地打包备份 =="
  mkdir -p /home/qch/backup
  TAR=/home/qch/backup/${NAME}-$TS.tar.gz
  tar -czf "$TAR" -C "$RUN" . 2>&1 | tail -2
  ls -lh "$TAR"
  tar -tzf "$TAR" | wc -l

  echo "== 5. 完整复制到仓库 export =="
  EX="$DIR/export/${NAME}_full"
  rm -rf "$EX"
  cp -a "$RUN" "$EX"
  echo "repo copy files: $(find "$EX" -type f | wc -l)"
  du -sh "$EX"
  echo "-- 目录树 --"
  find "$EX" -maxdepth 2 -type d | sort | head -20

  echo "== 6. 校验复制一致性 =="
  A=$(find "$RUN" -type f | sed "s|$RUN||" | sort | xargs -I{} sha256sum "$RUN{}" 2>/dev/null | sort)
  B=$(find "$EX" -type f | sed "s|$EX||" | sort | xargs -I{} sha256sum "$EX{}" 2>/dev/null | sort)
  if [ "$A" = "$B" ]; then echo "COPY VERIFIED: 全部文件 hash 一致"; else echo "COPY MISMATCH"; diff <(echo "$A") <(echo "$B") | head -10; fi

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
