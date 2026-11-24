#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。找 py312_litehost_gap_20261124_100323 的运行目录，并查 qemu 占核情况。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
ID=py312_litehost_gap_20261124_100323

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 在 vllm 容器里找 run 目录 =="
  docker exec "$C" bash -lc "find / -maxdepth 4 -type d -name '$ID' 2>/dev/null | head -5"
  docker exec "$C" bash -lc "ls -d /vllmBench /tmp/vllmBench /home/huawei_ts_program/litehost_perf_opt/vllmBench 2>/dev/null"

  echo "== 2. 找到就打印关键文件 =="
  P=$(docker exec "$C" bash -lc "find / -maxdepth 4 -type d -name '$ID' 2>/dev/null | head -1")
  if [ -n "$P" ]; then
    docker exec "$C" bash -lc "
      echo '-- config.txt'; cat '$P/config.txt' 2>/dev/null
      echo '-- 目录'; ls -la '$P' | head -8
      echo '-- server.log 关键行'; grep -nE 'loading took|capture|Capturing|startup complete|worker_cls' '$P/logs/server.log' 2>/dev/null | head -8
    "
  else
    echo "未找到 $ID"
  fi

  echo "== 3. qemu 测量工具的占核情况 =="
  ps -eo pid,psr,pcpu,comm --sort=-pcpu 2>/dev/null | head -6
  echo "-- qemu 进程与亲和 --"
  for p in $(pgrep -f qemu-system 2>/dev/null | head -3); do
    echo "pid=$p"
    ps -o pid,etime,pcpu,nlwp,args -p "$p" 2>/dev/null | cut -c1-110
    taskset -cp "$p" 2>/dev/null | tail -1
  done

  echo "== 4. 8/10/12/14 的占用 =="
  python3 - <<'PY'
import time
def stat():
    d={}
    for line in open("/proc/stat"):
        p=line.split()
        if p[0].startswith("cpu") and p[0][3:].isdigit():
            i=int(p[0][3:])
            if i in (8,10,12,14):
                v=list(map(int,p[1:]))
                d[i]=(sum(v), v[3]+v[4])
    return d
a=stat(); time.sleep(2); b=stat()
for i in (8,10,12,14):
    tot=b[i][0]-a[i][0] or 1; idle=b[i][1]-a[i][1]
    print(f"cpu{i}: busy={100*(tot-idle)/tot:.0f}%")
PY

  echo "== 5. 哪些进程在这些核上 =="
  ps -eLo pid,psr,pcpu,comm --sort=-pcpu 2>/dev/null | awk 'NR==1 || $2==8 || $2==10 || $2==12 || $2==14' | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
