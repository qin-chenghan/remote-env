#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 本次：只改 timeline_opt.sh 第 162 行的 --compilation-config，加 sample logits cudagraph。
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
  D=/home/qch/scripts
  F=$(ls -t "$D"/timeline*opt*.sh 2>/dev/null | head -1)
  echo "target=$F"
  [ -n "$F" ] || { echo "ABORT: 没找到 timeline*opt*.sh"; exit 6; }
  ls -l "$F"
  echo "-- 改前第 162 行 --"
  sed -n '162p' "$F"

  cp -a "$F" "$F.bak-cudagraph-$TS"

  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(True)
i = 161
if len(lines) <= i:
    raise SystemExit("FAIL: 文件不足 162 行")
old = lines[i]
if "--compilation-config" not in old:
    raise SystemExit("FAIL: 第 162 行不是 --compilation-config: " + old.strip())
if "sample_logits_cudagraph" in old:
    raise SystemExit("SKIP: 已包含 sample_logits_cudagraph")
if not old.rstrip().endswith("\\"):
    raise SystemExit("FAIL: 第 162 行未以反斜杠结尾")
indent = old[:len(old) - len(old.lstrip())]
new = indent + """--compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY", "mode":0, "sample_logits_cudagraph":"on", "sample_logits_cudagraph_max_bytes":67108864, "sample_logits_cudagraph_capture_sizes":[1,2,3,4,5,6,7,8]}' \\""" + "\n"
lines[i] = new
open(p, "w").writelines(lines)
print("OLD:", old.rstrip())
print("NEW:", new.rstrip())
PY
  echo "edit rc=$?"

  echo "-- 改后上下文 --"
  sed -n '160,164p' "$F"
  bash -n "$F" && echo "syntax OK"

  echo "-- 校验 --"
  grep -n 'sample_logits_cudagraph' "$F" | cut -c1-200

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
