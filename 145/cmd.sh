#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：从 145 ssh 到 198（198 无外网），在 198 的 vllm 容器里定位失败运行 100323。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

REMOTE=root@90.91.147.198
PROBE=/tmp/probe198.sh

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. ssh 连通性 =="
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'hostname; uname -m; nproc' 2>&1 | head -4

  echo "== 2. 写探测脚本到本机 =="
  cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "### host: $(hostname)  $(uname -m)  nproc=$(nproc)"

C=vllm
VB=/home/huawei_ts_program/litehost_perf_opt/vllmBench
ID=py312_litehost_gap_20261124_100323

echo "== 1. 容器 =="
docker ps --format '{{.Names}} {{.Image}} {{.Status}}' | head -8

echo "== 2. 容器里找 run 目录 =="
docker exec "$C" bash -lc "find / -maxdepth 6 -type d -name '$ID' 2>/dev/null | head -5"
docker exec "$C" bash -lc "ls -lt $VB 2>/dev/null | head -8"

P=$(docker exec "$C" bash -lc "find / -maxdepth 6 -type d -name '$ID' 2>/dev/null | head -1")
echo "P=$P"
if [ -n "$P" ]; then
  echo "== 3. config / 目录 =="
  docker exec "$C" bash -lc "cat '$P/config.txt' 2>/dev/null; ls -la '$P' | head -10"
  echo "== 4. server.log 关键行 =="
  docker exec "$C" bash -lc "grep -nE 'loading took|Capturing|startup complete|pinned to cpu|shm_broadcast|died unexpectedly' '$P/logs/server.log' | head -14"
  echo "== 5. summary =="
  docker exec "$C" bash -lc "cut -d, -f2,6,8,11 '$P/summary.csv' 2>/dev/null"
fi

echo "== 6. harness 日志（找 inductor_cache= 行）=="
docker exec "$C" bash -lc "
  ls -lt /tmp/run_*.log 2>/dev/null | head -5
  for f in \$(ls -t /tmp/run_*.log 2>/dev/null | head -4); do
    echo \"--- \$f\"; grep -m3 -E 'inductor_cache=|PREFIX=|TEST_ID=' \$f
  done" 2>&1 | head -20

echo "== 7. 缓存与解释器 =="
docker exec "$C" bash -lc '
  for c in /home/huawei_ts_program/inductor_cache_py312 /home/huawei_ts_program/inductor_cache_py311 /tmp/torchinductor_root; do
    echo -n "$c: "; [ -d $c ] && echo "files=$(find $c -name "*.py" 2>/dev/null | wc -l)" || echo missing
  done
  /usr/local/bin/python3 -V 2>&1; /opt/corex311/bin/python3 -V 2>&1'
docker inspect "$C" --format '{{json .Config.Env}}' | tr ',' '\n' | grep -iE "TORCHINDUCTOR|TORCHDYNAMO" || echo "镜像 ENV 无 TORCHINDUCTOR"

echo "== 8. qemu =="
ps -eo pid,psr,pcpu,nlwp,args | grep -i qemu | grep -v grep | cut -c1-140 | head -6
for p in $(pgrep -f qemu | head -3); do echo "pid=$p affinity: $(taskset -cp $p 2>/dev/null | tail -1)"; done
echo "-- 对端 IP --"
ss -tn 2>/dev/null | awk 'NR>1 {print $5}' | cut -d: -f1 | sort -u | head -8

echo "== 9. 抓栈工具 =="
command -v py-spy gdb perf 2>&1 | head -4
PROBE_EOF
ls -l "$PROBE"

  echo "== 3. 在 198 执行 =="
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE" 2>&1 | head -80

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
