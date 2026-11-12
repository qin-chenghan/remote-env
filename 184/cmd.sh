#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 补跑 150257 缺失的两步聚合：lhctl.py summary + analyze_litehost.py（写回原位置）。
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
  P=/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261112_150257
  dex() { timeout 300 docker exec "$C" bash -c "$1"; }

  echo "== 1. 参考脚本里的工具路径与清理环境 =="
  dex "grep -nE '^(HOST_TOOLKIT|PYTHON_BIN|HOST_LINK_PERCENT|CLEAN_ENV)=' /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh"
  dex "sed -n '/^CLEAN_ENV=/,/)$/p' /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh"

  echo "== 2. 定位工具 =="
  dex "find /home -maxdepth 3 -name 'lhctl.py' -o -maxdepth 3 -name 'analyze_litehost.py' 2>/dev/null | head"
  HT=$(timeout 60 docker exec "$C" bash -c "dirname \$(find /home -maxdepth 3 -name lhctl.py 2>/dev/null | head -1)")
  echo "HOST_TOOLKIT=$HT"
  [ -d "$HT" ] || { echo "找不到工具目录，结束"; exit 3; }
  dex "ls -l $HT/lhctl.py $HT/analyze_litehost.py"

  echo "== 3. 补跑 summary（生成 summary.csv + logs/summary_build.log）=="
  dex "cd $P && env -u PYTHONPATH -u PYTHONHOME -u LD_PRELOAD -u LD_AUDIT -u LD_DEBUG \
        -u VLLM_TORCH_PROFILER_DIR -u PROFILER_CONFIG -u TORCH_PROFILER_DIR \
        /opt/corex311-cpython-vllm/bin/python $HT/lhctl.py summary $P > $P/logs/summary_build.log 2>&1; \
        echo rc=\$?; tail -n 30 $P/logs/summary_build.log"

  echo "== 4. 补跑 analyze_litehost（生成 host_summary/）=="
  dex "env -u PYTHONPATH -u PYTHONHOME -u LD_PRELOAD -u LD_AUDIT \
        /opt/corex311-cpython-vllm/bin/python $HT/analyze_litehost.py $P/litehost \
        --link-percent 0 --out $P/host_summary --quiet; echo rc=\$?"

  echo "== 5. 产出检查 =="
  dex "ls -la --time-style=full-iso $P/summary.csv $P/host_summary 2>&1"
  echo "--- summary.csv ---"
  dex "cat $P/summary.csv 2>&1 | head -20"
  echo "--- host_summary/report.txt ---"
  dex "head -60 $P/host_summary/report.txt 2>&1"
  echo "--- host_summary/four_rank_totals.csv ---"
  dex "cat $P/host_summary/four_rank_totals.csv 2>&1"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
