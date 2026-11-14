#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：盘点 vllmBench 下最近的 run，识别 4K/64K 两份数据及产物完整性。
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
  C=corex5-py311
  R=/usr/local/corex-5.0.0/vllmBench
  dex() { timeout 120 docker exec "$C" bash -c "$1"; }

  echo "== 1. vllmBench 下的 run 列表（按时间）=="
  dex "ls -lat --time-style=long-iso $R | head -15"

  echo "== 2. 每个最近 run 的 config 与产物 =="
  dex "for d in \$(ls -dt $R/*/ | head -8); do
      echo \"===== \$d\"
      cat \$d/config.txt 2>/dev/null
      echo '--- summary ---'; head -5 \$d/summary.csv 2>/dev/null
      echo '--- host_summary ---'; ls \$d/host_summary 2>/dev/null || echo 无
      echo '--- case 目录 ---'; ls -d \$d/litehost/*/ 2>/dev/null | wc -l
    done"

  echo "== 3. run 里有没有记录内核/页大小的线索 =="
  dex "for d in \$(ls -dt $R/*/ | head -6); do
      echo \"===== \$d\"
      grep -riE 'uname|kernel|64k|page.?size|PAGE_SIZE|6\.6\.0-' \$d/config.txt \$d/logs/preflight.log \$d/session.json 2>/dev/null | head -5
      head -3 \$d/logs/server.log 2>/dev/null | cut -c1-160
    done"

  echo "== 4. 当前内核（仅作对照，不切）=="
  uname -r; getconf PAGE_SIZE

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
