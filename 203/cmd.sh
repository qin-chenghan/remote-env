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
  echo "### 本轮只读：只以 sqlite ro 打开 ixsys trace，不写、不删"
  set +x

  # ---- 命令开始 ----
  TRACE="/home/qch/1125analysis/ixsys_base/ixsys/bs8_in128_out128/bs8_in128_out128.ixsys.ptrace"

  echo "== 0. trace 文件 =="
  ls -l "$TRACE" 2>&1
  [[ -f "$TRACE" ]] || { echo "!! trace 不存在，检查路径"; ls -l /home/qch/1125analysis/ixsys_base/ixsys/*/* 2>&1 | head; }
  echo "-- 1125 三份目录 --"
  ls -d /home/qch/1125analysis/*/ 2>/dev/null
  echo "-- ixsys_base summary --"
  cat /home/qch/1125analysis/ixsys_base/summary.csv 2>&1
  echo "-- 空间 --"
  df -h /home | tail -1

  echo
  echo "== 1. 选择解释器（需 sqlite3）=="
  PY=""
  for c in /opt/corex311/bin/python3 python3 /usr/bin/python3; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sqlite3' >/dev/null 2>&1; then PY="$c"; break; fi
    echo "  跳过 $c"
  done
  if [[ -n "$PY" ]]; then
    echo "使用宿主解释器: $PY"
    "$PY" - <<'PYCHK'
import sqlite3, sys
p = "/home/qch/1125analysis/ixsys_base/ixsys/bs8_in128_out128/bs8_in128_out128.ixsys.ptrace"
db = sqlite3.connect("file:%s?mode=ro" % p, uri=True)
b = db.execute("select start_ts,end_ts from trace_bounds").fetchone()
print("trace_bounds: dur=%.1fs" % ((b[1]-b[0])/1e9))
for t in ("cuda_kernel_data","cuda_api_data","cuda_graph_data"):
    print("  %-18s rows=%d" % (t, db.execute("select count(*) from %s" % t).fetchone()[0]))
PYCHK
    "$PY" "$DIR/scripts/ixsys_cmp.py" "$TRACE|55|203-base"
  else
    echo "宿主 python 无 sqlite3，尝试容器 corex5-py311"
    docker exec corex5-py311 test -r "$DIR/scripts/ixsys_cmp.py" \
      && docker exec corex5-py311 /opt/corex311/bin/python3 "$DIR/scripts/ixsys_cmp.py" "$TRACE|55|203-base" \
      || echo "!! 容器内也拿不到脚本/trace"
  fi

  echo
  echo "== 2. ixsys 报告里的 GPU 汇总（若 server.log 留了）=="
  grep -aA3 "GPU Summary\|gpu summary\|Kernel Time" /home/qch/1125analysis/ixsys_base/logs/server.log 2>/dev/null | head -40 || echo "无"
  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
