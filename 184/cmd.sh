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
  # 第五批：fastpath 六个文件已与 32 完全一致，这里补查两个遗留点。
  # 严格只读。

  CON=corex5-py311
  BASE=/opt/corex311
  SP="$BASE/lib/python3.11/site-packages"

  echo "== 1. tokens 相关文件与 32 对照 =="
  docker exec "$CON" sh -c '
SP=/opt/corex311/lib/python3.11/site-packages
sha256sum $SP/vllm/v1/sample/sampler.py \
          $SP/vllm/model_executor/layers/logits_processor.py 2>/dev/null
for f in vllm/v1/sample/sampler.py \
         vllm/model_executor/layers/logits_processor.py \
         vllm/v1/worker/gpu_model_runner.py ; do
  echo -n "$f get_top_tokens="
  grep -c get_top_tokens $SP/$f 2>/dev/null || true
done
echo "-- hotspot-opt 发行版 --"
/opt/corex311/bin/pip show hotspot-opt 2>/dev/null | head -3 || echo "not installed as distribution"
'

  echo "== 2. 旧 metadata 补丁残留的状态 =="
  docker exec "$CON" sh -c '
SP=/opt/corex311/lib/python3.11/site-packages
D=$SP/vllm/.corex_metadata_patch
ls -la --time-style=long-iso $D 2>/dev/null
echo "-- state.json --"
cat $D/state.json 2>/dev/null
echo "-- 一个 rolled_back 记录 --"
for f in $D/*.rolled_back.json; do [ -f "$f" ] && { echo "---- $f"; cat "$f"; break; }; done
echo "-- originals 摘要（对照 MANIFEST 基线）--"
find $D/originals -type f -exec sha256sum {} \; 2>/dev/null
'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
