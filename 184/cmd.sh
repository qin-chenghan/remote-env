#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：历次 window.json 的失败分布、本次服务启动参数、shutdown 前原始日志。不跑测试。
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
  dex() { timeout 40 docker exec "$C" bash -c "$1"; }

  echo "== 1. 历次 run 里所有 failed 的 case（window.json）=="
  dex 'python3 - <<"PY"
import glob, json, os
rows=[]
for f in glob.glob("/usr/local/corex-5.0.0/vllmBench/*/litehost/*/window.json") + glob.glob("/home/z30059427/vllmBench/*/litehost/*/window.json"):
    try: d=json.load(open(f))
    except Exception: continue
    if d.get("status")=="failed":
        rows.append((f.split("/vllmBench/")[1], d.get("benchmark_duration_s"), d.get("successful"), d.get("failed"), str(d.get("error"))[:80]))
print("failed windows:", len(rows))
for r in sorted(rows): print(r)
PY'

  echo "== 2. 本次 run 目录列表（确认 101902 是不是 r14 装完后的第一次）=="
  dex "ls -lat /usr/local/corex-5.0.0/vllmBench/ | head -12"

  echo "== 3. 本次服务的启动参数（server.log 开头）=="
  dex "head -n 40 $P/logs/server.log"

  echo "== 4. r14/fastpath 相关开关在服务进程里是否出现 =="
  dex "grep -nE 'compact_greedy|host_opt|HOST_OPT|fastpath|positions|CUDAGraph|compilation-config' $P/logs/server.log | head -25"

  echo "== 5. shutdown 之前最后 120 行原始日志（不过滤）=="
  dex "sed -n '1380,1500p' $P/logs/server.log"

  echo "== 6. 当天 dmesg 全量（不筛选，看有无被过滤掉的异常）=="
  dmesg -T 2>/dev/null | awk '/Nov 13 1[01]:/' | tail -30

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
