#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 检查 r14 安装包内容与当前已安装版本，确定安装方式（先只读）。
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
  Z=/home/qch/transfer/host-opt-three-pr-validation-r14-arm64-py311-20261112.zip
  dex() { timeout 120 docker exec "$C" bash -c "$1"; }

  echo "== 1. 包文件本身 =="
  ls -l --time-style=full-iso "$Z" 2>&1
  sha256sum "$Z" 2>&1
  command -v unzip || echo "host 无 unzip"

  echo "== 2. 包内清单 =="
  unzip -l "$Z" 2>&1 | head -60
  echo "条目总数: $(unzip -l "$Z" 2>/dev/null | tail -1)"

  echo "== 3. 包内说明文档 =="
  for f in $(unzip -Z1 "$Z" 2>/dev/null | grep -Ei '\.(md|txt|rst|sh|json|yaml|yml)$' | head -10); do
    echo "--- $f ---"
    unzip -p "$Z" "$f" 2>&1 | head -80
    echo
  done

  echo "== 4. 当前已安装的相关包 =="
  dex "/opt/corex311-cpython-vllm/bin/pip list 2>/dev/null | grep -iE 'vllm|corex|iluvatar|torch' "
  echo "-- 两个 venv 的版本 --"
  dex "/opt/corex311/bin/pip list 2>/dev/null | grep -iE 'vllm|corex|iluvatar'"

  echo "== 5. 当前 venv 里之前 r10 的安装痕迹 =="
  dex "ls -la /opt/corex311-cpython-vllm/lib/python3.11/site-packages 2>/dev/null | head -30"
  dex "ls -d /opt/corex311-cpython-vllm/lib/python3.11/site-packages/*.dist-info 2>/dev/null | head -40"

  echo "== 6. 之前的安装记录（如果有）=="
  dex "ls -lat /home/qch/transfer/*.zip /home/qch/transfer/*.whl 2>/dev/null | head -20"
  dex "ls -lat /opt/corex311-cpython-vllm/*.bak* /opt/corex311-cpython-vllm/../*bak* 2>/dev/null | head"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
