#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 排查聚合失败：看 analyze_litehost 判定逻辑与 case.json 字段，并用实体拷贝重试。不跑 GPU。
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
  P=/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261113_101902
  V=/opt/corex311-cpython-vllm
  HT=/home/huawei_ts_program/litehost_perf_opt
  PY=$V/bin/python
  ENV="env -u PYTHONPATH -u PYTHONHOME -u LD_PRELOAD -u LD_AUDIT -u VLLM_TORCH_PROFILER_DIR"
  dex() { timeout 300 docker exec "$C" bash -c "$1"; }

  echo "== 1. 工具里这条报错的判定逻辑 =="
  dex "grep -n 'No new-format case.json' -B 20 -A 10 $HT/analyze_litehost.py"

  echo "== 2. 有效 case 的 case.json / window.json 字段 =="
  dex "python3 - <<'PY'
import json,glob
for d in sorted(glob.glob('$P/litehost/*/')):
    try:
        c=json.load(open(d+'case.json'))
        w=json.load(open(d+'window.json'))
    except Exception as e:
        print(d,'ERR',e); continue
    print(d.split('/')[-2], '| case keys:', sorted(c)[:8], '| status:', c.get('status'), '| window status:', w.get('status'), '| keys:', sorted(w)[:8])
PY"

  echo "== 3. 用实体拷贝重试（不用软链）=="
  dex "rm -rf /tmp/lh7c && mkdir -p /tmp/lh7c
    for d in $P/litehost/*/; do
      n=\$(basename \$d)
      ls \$d | grep -q 'rank0_pid' && cp -a \$d /tmp/lh7c/\$n
    done
    du -sh /tmp/lh7c; ls /tmp/lh7c"
  dex "cd /tmp/lh7c && $ENV $PY $HT/analyze_litehost.py /tmp/lh7c --link-percent 0 --out /tmp/lh7c_out --quiet > /tmp/lh7c.log 2>&1; echo rc=\$?; tail -20 /tmp/lh7c.log"
  dex "ls -l /tmp/lh7c_out 2>&1; head -5 /tmp/lh7c_out/four_rank_totals.csv 2>&1"

  echo "== 4. 若仍失败，看单 case 直接分析的结果 =="
  dex "if [ ! -f /tmp/lh7c_out/four_rank_totals.csv ]; then
      D=$P/litehost/bs8_in128_out128
      rm -rf /tmp/lh1 && mkdir -p /tmp/lh1 && cp -a \$D /tmp/lh1/
      $ENV $PY $HT/analyze_litehost.py /tmp/lh1 --link-percent 0 --out /tmp/lh1_out --quiet 2>&1 | tail -20
      echo rc=\$?
      ls -l /tmp/lh1_out 2>&1
    else echo '拷贝目录聚合成功'; fi"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
