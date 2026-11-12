#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：确认 metadata 快路径在已安装版本里的实际开关方式。
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
  PKG=/home/qch/transfer/host-opt-pr-validation-20261106-r10
  SITE=/opt/corex311/lib/python3.11/site-packages

  echo "== 实际安装用的 container patch =="
  ls -l "$PKG/container/patches" 2>&1
  grep -n 'VLLM_HOST_OPT_METADATA\|environ\|getenv' "$PKG/container/patches/0002-ilu-metadata.patch" 2>&1 | head -12

  echo "== 已安装包里是否有该字符串 =="
  docker exec corex5-py311 grep -rn 'VLLM_HOST_OPT_METADATA' "$SITE/vllm" 2>/dev/null | head -5
  echo "(空=没有)"

  echo "== ilu_flash_attn.py 100-130 行 =="
  docker exec corex5-py311 sed -n '100,130p' "$SITE/vllm/v1/attention/backends/ilu_flash_attn.py" 2>&1 | cut -c1-170

  echo "== 本次 run 有没有 metadata off 日志 =="
  grep -c 'host attention metadata off' /home/qch/scripts/timeline/4k/logs/server.log 2>&1
  grep -n 'host attention metadata' /home/qch/scripts/timeline/4k/logs/server.log 2>&1 | head -5

  echo "== 本次 run 的 attention backend / ilu 日志 =="
  grep -iE 'IluFlashAttention|ilu_flash_attn|attention backend|_host_opt_meta_native' /home/qch/scripts/timeline/4k/logs/server.log 2>&1 | cut -c1-190 | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
