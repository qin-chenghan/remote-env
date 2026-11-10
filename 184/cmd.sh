#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 本次任务：清理空备份、补一份真备份、在 base 上跑 r10 verify.py。
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
  SITE=/opt/corex311/lib/python3.11/site-packages
  PY=/opt/corex311/bin/python3
  R10=/home/qch/transfer/host-opt-pr-validation-20261106-r10

  echo "== cleanup empty backup =="
  ls -l /home/qch/backup/corex311-vllm-pre-r10-20261110-101804.tar.gz 2>&1
  [ "$(stat -c %s /home/qch/backup/corex311-vllm-pre-r10-20261110-101804.tar.gz 2>/dev/null || echo 0)" -lt 100 ] \
    && rm -f /home/qch/backup/corex311-vllm-pre-r10-20261110-101804.tar.gz \
    && echo "removed empty gz"
  ls -l /home/qch/backup/ 2>&1 | head

  echo "== real backup (inside container) =="
  docker exec corex5-py311 tar -czf "/home/qch/backup/corex311-vllm-r10-$TS.tar.gz" \
    -C "$SITE" vllm .host-opt-pr-backup 2>&1 | tail -5
  echo "rc=${PIPESTATUS[0]}"
  ls -lh "/home/qch/backup/corex311-vllm-r10-$TS.tar.gz" 2>&1

  echo "== verify r10 on base venv =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME \
    "$PY" "$R10/scripts/verify.py" --root "$SITE" 2>&1 | tail -30
  echo "verify rc=${PIPESTATUS[0]}"

  echo "== final check =="
  docker exec corex5-py311 env -u PYTHONPATH -u PYTHONHOME "$PY" "$R10/scripts/install.py" \
    --root "$SITE" --check 2>&1 | tail -4

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
