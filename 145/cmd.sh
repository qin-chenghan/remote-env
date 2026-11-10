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
  # 只读：运行前检查——二进制、依赖、绑核可行性、当前各核负载。

  echo "== 1. 两个二进制 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
cd "$P"
ls -l fusion.unittest fusion.unittest.bak_before_neon
md5sum fusion.unittest fusion.unittest.bak_before_neon
for b in fusion.unittest fusion.unittest.bak_before_neon; do
  echo "-- $b --"
  file "$b"
  ldd "$b" 2>&1 | grep -iE "kperf|not found" | head -5
  nm -C "$b" 2>/dev/null | grep -c "PillowFusionV2"
done
' 2>&1 | head -40

  echo "== 2. 反汇编：sqxtun 指令数量 =="
  docker exec fusionv1 bash -lc '
P=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
cd "$P"
for b in fusion.unittest.bak_before_neon fusion.unittest; do
  printf "%-38s sqxtun=%s uqxtn=%s\n" "$b" \
    "$(objdump -d "$b" 2>/dev/null | grep -c sqxtun)" \
    "$(objdump -d "$b" 2>/dev/null | grep -c uqxtn)"
done
' 2>&1 | head -10

  echo "== 3. libkperf 依赖 =="
  docker exec fusionv1 bash -lc '
ls -l /home/workspace/tensor/files/libkperf 2>&1 | head -10
' 2>&1 | head -15

  echo "== 4. numactl 与拓扑（确认核 0/3 属于 node0）=="
  docker exec fusionv1 bash -lc '
command -v numactl || echo NO_NUMACTL
numactl -s 2>&1 | head -5
numactl -H 2>&1 | grep -E "^node [0-9] cpus|^available" | head -5
head -1 /sys/devices/system/cpu/cpu0/topology/core_id 2>/dev/null; echo "^cpu0 core_id"
cat /sys/devices/system/cpu/cpu0/node*/link 2>/dev/null | head -2
' 2>&1 | head -20

  echo "== 5. 当前各核负载（1 秒采样）=="
  docker exec fusionv1 bash -lc '
python3 - <<"PY"
import time
def rd():
    d={}
    for line in open("/proc/stat"):
        p=line.split()
        if p[0].startswith("cpu") and p[0][3:].isdigit():
            v=[int(x) for x in p[1:]]
            d[int(p[0][3:])]=(sum(v), v[3]+(v[4] if len(v)>4 else 0))
    return d
a=rd(); time.sleep(1); b=rd()
res=[]
for c in a:
    dt=b[c][0]-a[c][0]; di=b[c][1]-a[c][1]
    if dt>0: res.append((100.0*(dt-di)/dt, c))
res.sort(reverse=True)
print("busy cores (top10):")
for p,c in res[:10]: print("  cpu%-3d %5.1f%%" % (c,p))
for c in (0,1,2,3):
    q=[x for x in res if x[1]==c]
    print("  target cpu%d: %.1f%%" % (c, q[0][0] if q else -1))
PY
' 2>&1 | head -25

  echo "== 6. 当前负载与占核进程 =="
  docker exec fusionv1 bash -lc '
cat /proc/loadavg
ps -eo pid,pcpu,psr,comm --sort=-pcpu 2>/dev/null | head -8
' 2>&1 | head -15

  echo "== 7. 宿主机负载 =="
  uptime
  cat /proc/loadavg

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
