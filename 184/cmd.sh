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
  # 第六批：确认旧 metadata 补丁新增的 4 个辅助文件是否残留、是否被引用。
  # 严格只读。

  CON=corex5-py311
  SP=/opt/corex311/lib/python3.11/site-packages

  docker exec "$CON" sh -c '
SP=/opt/corex311/lib/python3.11/site-packages
echo "== 1. vllm/iluvatar 列表 =="
ls -la --time-style=long-iso $SP/vllm/iluvatar/ 2>/dev/null

echo "== 2. 旧补丁新增的 4 个辅助文件 =="
for f in metadata_optimization.py native_input_metadata.py native_spec_metadata.py input_pipeline.py; do
  if [ -f "$SP/vllm/iluvatar/$f" ]; then sha256sum "$SP/vllm/iluvatar/$f"; else echo "MISSING $f"; fi
done

echo "== 3. 谁引用这些模块 =="
grep -rn "metadata_optimization\|native_input_metadata\|native_spec_metadata\|input_pipeline" $SP/vllm --include="*.py" 2>/dev/null \
  | grep -vE "iluvatar/(metadata_optimization|native_input_metadata|native_spec_metadata|input_pipeline)\.py:" \
  | head -30

echo "== 4. 其他 metadata fastpath 残留 =="
find $SP -maxdepth 2 \( -name "*metadata*fastpath*" -o -name "corex_metadata*" \) 2>/dev/null | head -20
'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
