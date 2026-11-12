#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 解压 r14 包、校验、看安装器用法，并确认当前 r10 装在哪个 venv。
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
  W=/home/qch/transfer/r14
  D=$W/host-opt-pr-validation-20261106-r14
  dex() { timeout 180 docker exec "$C" bash -c "$1"; }

  echo "== 1. 解压 =="
  rm -rf "$W"
  mkdir -p "$W"
  unzip -q "$Z" -d "$W"
  ls -la "$D"

  echo "== 2. 校验 SHA256SUMS =="
  ( cd "$D" && sha256sum -c SHA256SUMS 2>&1 | tail -8 )

  echo "== 3. 安装器用法 =="
  dex "/opt/corex311-cpython-vllm/bin/python $D/scripts/install.py --help"
  echo "--- verify.py ---"
  dex "/opt/corex311-cpython-vllm/bin/python $D/scripts/verify.py --help"

  echo "== 4. 两个 venv 的当前状态 =="
  for V in /opt/corex311 /opt/corex311-cpython-vllm; do
    SP=$V/lib/python3.11/site-packages
    echo "---- $V ----"
    dex "ls -ld $SP/.host-opt-pr-backup 2>&1"
    dex "ls $SP/.host-opt-pr-backup 2>/dev/null | head"
    dex "ls -l $SP/vllm/v1/worker/host_opt.py $SP/vllm/v1/worker/compact_greedy_backport.py $SP/vllm/model_executor/layers/output_head.py 2>&1"
    echo -n "envs.py 里 POSITIONS 出现次数: "
    dex "grep -c VLLM_HOST_OPT_POSITIONS $SP/vllm/envs.py 2>/dev/null || echo 0"
    echo -n "compilation.py 里 compact_greedy 出现次数: "
    dex "grep -c compact_greedy $SP/vllm/config/compilation.py 2>/dev/null || echo 0"
    echo "ROOT 解析:"
    dex "$V/bin/python -I -c 'import importlib.util,pathlib; print(pathlib.Path(next(iter(importlib.util.find_spec(\"vllm\").submodule_search_locations))).parent)'"
  done

  echo "== 5. 是否有 vllm 服务在跑 =="
  dex "ps -eo pid,etime,args | grep -E 'vllm|api_server' | grep -v grep | head -10"
  dex "ss -ltnp 2>/dev/null | grep -E ':88|:80' | head -10"

  echo "== 6. 容器里编译环境 =="
  dex "which cmake gcc g++ ninja 2>&1; cmake --version 2>/dev/null | head -1; gcc --version | head -1"
  dex "df -h /opt | tail -1"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
