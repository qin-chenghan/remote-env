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
  OLD_TC=/home/huawei_ts_program/gperftools/.libs/libtcmalloc.so
  NEW_TC=/home/lw/gperftools/.libs/libtcmalloc.so

  echo "== patch: python env + tcmalloc path (idempotent) =="
  for f in vllmBench_lite_base.sh vllmBench_lite_opt.sh; do
    echo "-- $f"
    cp -a "$D/$f" "$D/$f.bak-fix-$TS2"
    python3 - "$D/$f" "$OLD_TC" "$NEW_TC" <<'PY'
import sys
p, old_tc, new_tc = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
edits = [
    ('CLEAN_ENV=(env -u LD_PRELOAD',
     'CLEAN_ENV=(env -u PYTHONPATH -u PYTHONHOME -u LD_PRELOAD'),
    ('PYTHONPATH="${HOST_TOOLKIT}${PYTHONPATH:+:$PYTHONPATH}"',
     'PYTHONPATH="$HOST_TOOLKIT"'),
    (old_tc, new_tc),
]
changed = False
for old, new in edits:
    if old in s:
        print(f"  applied: {old[:60]}")
        s = s.replace(old, new)
        changed = True
    elif new in s:
        print(f"  already: {new[:60]}")
    else:
        print(f"  SKIP (not found): {old[:60]}")
if changed:
    open(p, "w").write(s)
PY
    bash -n "$D/$f" && echo "  syntax OK"
  done

  echo "== remaining old-path refs =="
  grep -rn 'huawei_ts_program/gperftools' "$D" 2>/dev/null | head -10

  echo "== final lines =="
  grep -n 'CLEAN_ENV=(env\|PYTHONPATH=\|libtcmalloc' "$D"/vllmBench_lite_*.sh 2>&1

  echo "== tcmalloc sanity =="
  ls -l "$NEW_TC" 2>&1
  file -b "$NEW_TC" 2>&1
  env LD_PRELOAD="$NEW_TC" /bin/true; echo "  preload exit=$?"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
