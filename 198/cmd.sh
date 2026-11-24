#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。定位 198 的 vllm 容器里 py312_litehost_gap_20261124_100323 那次运行，
#       并查看 qemu 与容器的现状。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
VB=/home/huawei_ts_program/litehost_perf_opt/vllmBench
ID=py312_litehost_gap_20261124_100323

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### repo:   $ROOT"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 机器与容器 =="
  uname -m; nproc; free -g | head -2
  docker ps --format '{{.Names}} {{.Image}} {{.Status}}' | head -8

  echo "== 2. vllm 容器里找 run 目录（深 6 层）=="
  docker exec "$C" bash -lc "find / -maxdepth 6 -type d -name '$ID' 2>/dev/null | head -5"
  docker exec "$C" bash -lc "ls -lt $VB 2>/dev/null | head -8"

  echo "== 3. 找到后打印关键信息 =="
  P=$(docker exec "$C" bash -lc "find / -maxdepth 6 -type d -name '$ID' 2>/dev/null | head -1")
  echo "P=$P"
  if [ -n "$P" ]; then
    docker exec "$C" bash -lc "
      echo '-- config.txt'; cat '$P/config.txt' 2>/dev/null
      echo '-- 文件'; ls -la '$P' | head -10
      echo '-- server.log 关键行'
      grep -nE 'loading took|Capturing|startup complete|pinned to cpu|shm_broadcast|died unexpectedly' '$P/logs/server.log' | head -14
      echo '-- summary'; cut -d, -f2,6,8,11 '$P/summary.csv' 2>/dev/null
    " 2>&1 | head -40
  fi

  echo "== 4. harness 侧日志（会打印 inductor_cache=...）=="
  docker exec "$C" bash -lc "ls -lt /tmp/run_*${ID}*.log /tmp/run_*py312*.log 2>/dev/null | head -5"
  docker exec "$C" bash -lc "
    for f in \$(ls -t /tmp/run_*py312*.log 2>/dev/null | head -3); do
      echo \"--- \$f\"; grep -m2 -E 'inductor_cache=|PREFIX=|TEST_ID=' \$f
    done" 2>&1 | head -14

  echo "== 5. 缓存与解释器 =="
  docker exec "$C" bash -lc '
    for c in /home/huawei_ts_program/inductor_cache_py312 /home/huawei_ts_program/inductor_cache_py311 /tmp/torchinductor_root; do
      echo -n "$c: "; [ -d $c ] && echo "files=$(find $c -name "*.py" 2>/dev/null | wc -l)" || echo missing
    done
    /usr/local/bin/python3 -V 2>&1; /opt/corex311/bin/python3 -V 2>&1'
  docker inspect "$C" --format '{{json .Config.Env}}' | tr ',' '\n' | grep -iE "TORCHINDUCTOR|TORCHDYNAMO" || echo "镜像 ENV 无 TORCHINDUCTOR"

  echo "== 6. qemu（198 上负责监听的工具）=="
  ps -eo pid,psr,pcpu,nlwp,args 2>/dev/null | grep -i qemu | grep -v grep | cut -c1-150 | head -6
  for p in $(pgrep -f qemu 2>/dev/null | head -3); do
    echo "pid=$p affinity: $(taskset -cp $p 2>/dev/null | tail -1)"
  done
  echo "-- qemu 的网络连接（看连向哪台机器）--"
  ss -tnp 2>/dev/null | grep -i qemu | head -6 || echo "无 qemu 连接"
  ss -tnp 2>/dev/null | awk 'NR>1 {print $5}' | cut -d: -f1 | sort -u | head -8

  echo "== 7. 抓栈工具 =="
  command -v py-spy gdb perf 2>&1 | head -4

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
