#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：安装 base 配置的 timeline 采集脚本到 /home/qch/scripts/litehost_perf，
#       并做可用性检查（语法 / 路径 / 版本 / 拓扑 / dry-run / 小规模冒烟）。
#       冒烟默认执行，SMOKE=0 可跳过。
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

  SRC="$DIR/scripts/vllmBench_lite_base_timeline.sh"
  DST_DIR=/home/qch/scripts/litehost_perf
  DST="$DST_DIR/vllmBench_lite_base_timeline.sh"
  CONTAINER=corex5-py311
  SMOKE="${SMOKE:-1}"

  echo "== 1. 安装脚本 =="
  ls -l "$SRC"
  mkdir -p "$DST_DIR"
  if [ -f "$DST" ]; then cp -p "$DST" "$DST.bak-$TS"; echo "旧脚本已备份: $DST.bak-$TS"; fi
  install -m 644 "$SRC" "$DST"
  sha256sum "$SRC" "$DST"
  bash -n "$DST" && echo "syntax ok"

  echo "== 2. 主机侧前置 =="
  echo "-- 模型目录"
  ls -ld /home/hc/modules/Qwen3-32B-W8A8 2>&1
  ls /home/hc/modules/Qwen3-32B-W8A8 2>&1 | head -8
  echo "-- 工具包"
  ls -d /home/qch/transfer/litehost_perf 2>/dev/null
  ls /home/qch/transfer/litehost_perf 2>&1 | head -12
  echo "-- 驱动与设备"
  uname -r
  ls -l /dev/iluvatar* 2>&1 | head -6
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null
  IXSMI="$(command -v ixsmi || echo /usr/local/corex-5.0.0/bin/ixsmi)"
  echo "ixsmi=$IXSMI"
  "$IXSMI" 2>&1 | grep -E "Iluvatar|MiB /" | head -10
  echo "-- GPU 的 NUMA 节点与绑核核对"
  for d in /sys/bus/pci/drivers/iluvatar/*/; do
    [ -e "$d/numa_node" ] && echo "$(basename "$d") numa_node=$(cat "$d/numa_node")"
  done
  cat /sys/devices/system/node/node0/cpulist 2>&1
  echo "-- 磁盘"
  df -h /home | tail -1

  echo "== 3. 容器内环境 =="
  docker ps --filter "name=$CONTAINER" --format '{{.Names}} {{.Status}}'
  if ! docker ps --filter "name=$CONTAINER" --format '{{.Names}}' | grep -q "$CONTAINER"; then
    echo "!! 容器 $CONTAINER 未运行；请先 docker start $CONTAINER（本脚本不自动启动）"
  fi
  ls -d "$DST_DIR/vllmBench" 2>&1
  docker exec "$CONTAINER" bash -lc 'ls -l /opt/corex311/bin/python3'
  docker exec "$CONTAINER" bash -lc '/opt/corex311/bin/python3 -c "import vllm,torch,triton;print(vllm.__version__,torch.__version__,triton.__version__)"' 2>&1 | tail -3
  echo "-- 容器内能看到模型与工具包吗"
  docker exec "$CONTAINER" bash -lc 'ls -ld /home/hc/modules/Qwen3-32B-W8A8 2>&1; ls -l /home/qch/transfer/litehost_perf/procutil.py 2>&1; ls /home/qch/transfer/litehost_perf/lhctl.py 2>&1'

  echo "== 4. dry-run（不启动服务）=="
  docker exec "$CONTAINER" bash -lc "cd $DST_DIR && HOST_DRY_RUN=1 TEST_ID=usability-dryrun bash $DST" 2>&1 | tail -6

  echo "== 5. 端口与卡的状态 =="
  docker exec "$CONTAINER" bash -lc 'ss -ltn 2>/dev/null | grep -E ":8848" || echo "no listener on 8848 (或容器内无 ss)"'
  pgrep -af vllm.entrypoints.openai.api_server | grep -v "bash -c" | head -3 || true

  if [ "$SMOKE" = 1 ]; then
    echo "== 6. 小规模冒烟（128/64，8 prompts，0 warmup，产出小 trace）=="
    FREE_OK=1
    for g in 0 1 2 3; do
      FREE=$("$IXSMI" --query-gpu=memory.free --format=csv,noheader,nounits -i "$g" 2>/dev/null | tr -d ' ')
      echo "GPU $g free=${FREE:-unknown} MiB"
      if [ -n "${FREE:-}" ] && [ "$FREE" -lt 20480 ] 2>/dev/null; then FREE_OK=0; fi
    done
    if [ -e /dev/iluvatar0 ] && [ "$FREE_OK" = 1 ]; then
      docker exec "$CONTAINER" bash -lc 'echo "128 64" > /tmp/smoke_cases.txt'
      docker exec "$CONTAINER" bash -lc "cd $DST_DIR && TEST_ID=smoke-timeline-$TS NUM_PROMPTS=8 NUM_WARMUPS=0 CASES_FILE=/tmp/smoke_cases.txt bash $DST" 2>&1 | tail -25
      echo "-- 冒烟产物"
      ls -la "$DST_DIR/vllmBench/smoke-timeline-$TS/timeline" 2>&1 | head -10
      du -sh "$DST_DIR/vllmBench/smoke-timeline-$TS" 2>/dev/null
      echo "-- 服务端日志尾部（查错误）"
      grep -inE "ERROR|Traceback|OOM|CUDA" "$DST_DIR/vllmBench/smoke-timeline-$TS/logs/server.log" 2>/dev/null | head -8
      echo "-- 冒烟后残留进程（本脚本不会自动杀，需人工确认）"
      pgrep -af vllm.entrypoints.openai.api_server | grep -v "bash -c" | head -5 || echo "无残留"
    else
      echo "跳过冒烟：设备不存在或显存不满足（FREE_OK=$FREE_OK）"
    fi
  else
    echo "== 6. 冒烟已按 SMOKE=0 跳过 =="
  fi

  echo "== 7. 正式采集命令（确认无误后手动执行）=="
  echo "docker exec $CONTAINER bash -lc 'cd $DST_DIR && TEST_ID=base-timeline-1119 bash $DST'"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
