#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：查 metadata 快路径的真实开关名与是否已在运行。
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
  PKG=/home/qch/transfer/host-opt-pr-validation-20261106-r10

  echo "== envs.py 里所有 VLLM_HOST_OPT* 名字 =="
  docker exec corex5-py311 grep -oE '"VLLM_HOST_OPT[A-Z_]*"' "$SITE/vllm/envs.py" 2>&1 | sort -u

  echo "== envs.py 里 META 相关 =="
  docker exec corex5-py311 grep -nE 'META|metadata' "$SITE/vllm/envs.py" 2>&1 | head -10

  echo "== 谁引用 _host_opt_meta_native =="
  docker exec corex5-py311 grep -rn '_host_opt_meta_native' "$SITE/vllm" 2>&1 | head -10

  echo "== ilu_flash_attn 里的 metadata =="
  docker exec corex5-py311 grep -n 'metadata' "$SITE/vllm/v1/attention/backends/ilu_flash_attn.py" 2>&1 | head -15

  echo "== host_opt.py 模式解析段 =="
  docker exec corex5-py311 sed -n '60,120p' "$SITE/vllm/v1/worker/host_opt.py" 2>&1 | cut -c1-160

  echo "== r10 源码里有没有 VLLM_HOST_OPT_METADATA =="
  grep -rn 'VLLM_HOST_OPT_METADATA' "$PKG" 2>/dev/null | head -10
  grep -rln 'metadata' "$PKG/source" 2>/dev/null | head -10

  echo "== r10 文档/清单里的 metadata 开关 =="
  grep -rn 'METADATA' "$PKG"/MANIFEST* "$PKG"/README* "$PKG"/docs 2>/dev/null | head -10

  echo "== 本次 run 是否出现 metadata 警告 =="
  grep -n 'Host metadata arena unavailable\|metadata' /home/qch/scripts/timeline/4k/logs/server.log 2>/dev/null | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
