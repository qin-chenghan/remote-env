#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。取 09:57 那次 server.log 的中间段（启动完成到 EngineCore 死亡），并查 /dev/shm。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
RUN=/home/huawei_ts_program/litehost_perf_opt/vllmBench/litehost_gap_20261120_095754

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. server.log 规模 =="
  docker exec "$C" bash -lc "wc -l $RUN/logs/server.log; grep -n -E 'ERROR|Traceback|RuntimeError|startup complete|Waiting for application' $RUN/logs/server.log | head -20" 2>&1

  echo "== 2. 日志中间段（40-160 行）=="
  docker exec "$C" bash -lc "sed -n '40,160p' $RUN/logs/server.log" 2>&1 | grep -v "Can't initialize NVML" | grep -v "raw_cnt =" | head -45

  echo "== 3. /dev/shm 容量（两个容器对比）=="
  for c in vllm corex5-py311-mock; do
    echo "-- $c"
    docker exec "$c" bash -lc 'df -h /dev/shm | tail -1; ls /dev/shm | head -3' 2>&1
  done

  echo "== 4. 容器实际挂载 =="
  docker inspect "$C" --format '{{json .HostConfig.Binds}} ShmSize={{.HostConfig.ShmSize}}'
  docker inspect corex5-py311-mock --format '{{json .HostConfig.Binds}} ShmSize={{.HostConfig.ShmSize}}'

  echo "== 5. 那次 run 的 harness 包装日志（若有）=="
  docker exec "$C" bash -lc '
    ls -lt /home/qch/transfer/*.log /tmp/*vllmBench*.log 2>/dev/null | head -5
    for f in $(ls -t /home/qch/transfer/*.log 2>/dev/null | head -2); do echo "--- $f"; tail -8 "$f"; done
  ' 2>&1 | head -20

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
