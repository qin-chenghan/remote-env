#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：看打补丁后的 benchmark 源码和请求失败标记路径，不跑任何测试。
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
  P=/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261113_101902
  SP=/opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm
  dex() { timeout 40 docker exec "$C" bash -c "$1"; }

  echo "== 1. 打补丁后的 benchmark 源码（保留在失败 case 目录）=="
  dex "cat $P/litehost/bs8_in2048_out1024/benchmark_hooked.py.txt"

  echo "== 2. 正式请求循环与失败统计（serve.py）=="
  dex "grep -n 'asyncio.gather\|success\|failed' $SP/benchmarks/serve.py | head -40"

  echo "== 3. 请求函数里 success=False 的位置 =="
  dex "grep -rn 'success = False\|success=False\|raise' $SP/benchmarks/lib/endpoint_request_func.py | head -30"

  echo "== 4. 请求函数异常处理段 =="
  dex "sed -n '/async def async_request_/,/^async def /p' $SP/benchmarks/lib/endpoint_request_func.py | head -80"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
