#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。为"捕获卡死"复现做准备：工具、核占用、缓存位置、容器状态。
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

  echo "== 1. 诊断工具 =="
  command -v py-spy gdb perf mpstat pidstat sar 2>&1 | head -8
  docker exec corex5-py311-mock bash -lc 'command -v py-spy gdb perf 2>&1 | head -4' 2>&1

  echo "== 2. 两个容器的状态 =="
  docker ps --format '{{.Names}} {{.Status}}' | grep -E "vllm|corex5-py311-mock" || true
  ss -ltn 2>/dev/null | grep -E ':(8948|8848)\b' || echo "8948/8848 free"

  echo "== 3. 关键缓存位置 =="
  echo "-- vllm 容器内（它自己的 /home）"
  docker exec vllm bash -lc 'for c in /home/huawei_ts_program/inductor_cache_py312 /home/huawei_ts_program/inductor_cache_py311 /tmp/torchinductor_root; do echo -n "$c: "; [ -d $c ] && echo "files=$(find $c -name "*.py" | wc -l) mtime=$(stat -c %y $c | cut -d. -f1)" || echo missing; done'
  echo "-- 宿主 /home（mock 容器可见的那份）"
  for c in /home/huawei_ts_program/inductor_cache_py312 /home/huawei_ts_program/inductor_cache_py311 /tmp/torchinductor_root; do
    echo -n "$c: "; [ -d "$c" ] && echo "files=$(find "$c" -name '*.py' 2>/dev/null | wc -l)" || echo missing
  done

  echo "== 4. 指定核当前的占用（8/10/12/14）=="
  python3 - <<'PY'
import time
def stat():
    out={}
    for i in (8,10,12,14):
        try:
            f=open(f"/proc/stat").read().splitlines()
        except Exception: return None
        for line in f:
            p=line.split()
            if p[0]==f"cpu{i}":
                vals=list(map(int,p[1:]))
                idle=vals[3]+vals[4]
                out[i]=(sum(vals), idle)
    return out
a=stat(); time.sleep(2); b=stat()
for i in (8,10,12,14):
    tot=b[i][0]-a[i][0]; idle=b[i][1]-a[i][1]
    busy=100*(tot-idle)/tot if tot else 0
    print(f"cpu{i}: busy={busy:.0f}%")
PY

  echo "== 5. 该核上跑着什么 =="
  ps -eo pid,psr,pcpu,comm --sort=-pcpu 2>/dev/null | awk 'NR==1 || $2==8 || $2==10 || $2==12 || $2==14' | head -8

  echo "== 6. 容器内是否设置了缓存环境变量（来自镜像 ENV）=="
  docker inspect vllm --format '{{json .Config.Env}}' | tr ',' '\n' | grep -iE "TORCHINDUCTOR|TORCHDYNAMO" || echo "镜像 ENV 无相关变量（说明只能靠脚本注入）"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
