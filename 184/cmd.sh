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
  D=/home/huawei_ts_program/litehost_perf_opt
  TS2=$(date +%Y%m%d-%H%M%S)

  echo "== patch: strip inherited PYTHONPATH =="
  for f in vllmBench_lite_base.sh vllmBench_lite_opt.sh; do
    echo "-- $f"
    cp -a "$D/$f" "$D/$f.bak-pyenv-$TS2"
    python3 - "$D/$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
edits = [
    ('CLEAN_ENV=(env -u LD_PRELOAD',
     'CLEAN_ENV=(env -u PYTHONPATH -u PYTHONHOME -u LD_PRELOAD'),
    ('PYTHONPATH="${HOST_TOOLKIT}${PYTHONPATH:+:$PYTHONPATH}"',
     'PYTHONPATH="$HOST_TOOLKIT"'),
]
for old, new in edits:
    n = s.count(old)
    print(f"  {n}x {old[:48]}")
    s = s.replace(old, new)
if s == open(p).read():
    raise SystemExit(f"  no change in {p}")
open(p, "w").write(s)
PY
    bash -n "$D/$f" && echo "  syntax OK"
    grep -n 'CLEAN_ENV=(env\|PYTHONPATH=' "$D/$f" | head -6
  done

  echo "== verify: clean-env import =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME PYTHONPATH="$D" \
    /opt/corex311/bin/python3 -c "import torch,vllm;print('base ok',torch.__version__,vllm.__version__)" 2>&1 | tail -3
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME PYTHONPATH="$D" \
    /opt/corex311-cpython-vllm/bin/python3 -c "import torch,vllm;print('pgo ok',torch.__version__,vllm.__version__)" 2>&1 | tail -3

  echo "== tcmalloc status =="
  ls -l /home/huawei_ts_program/gperftools/.libs/libtcmalloc.so 2>&1
  ls -l /home/lw/gperftools/.libs/libtcmalloc.so 2>&1
  grep -n 'libtcmalloc' "$D"/vllmBench_lite_*.sh 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
