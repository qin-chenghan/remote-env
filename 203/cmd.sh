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
  SRC="$DIR/scripts"
  DST=/home/qch/scripts/litehost_perf
  mkdir -p "$DST"

  echo "== 0. 安装三份 base 采集脚本 + 驱动（会覆盖同名旧文件，先备份差异）=="
  for f in vllmBench_lite_base.sh vllmBench_lite_base_timeline.sh \
           timeline_ixsys_base.sh run_1125_203.sh; do
    if [[ -f "$DST/$f" && ! "$SRC/$f" -ef "$DST/$f" ]] && ! cmp -s "$SRC/$f" "$DST/$f"; then
      cp -a "$DST/$f" "$DST/$f.bak-$TS"
    fi
    install -m 0755 "$SRC/$f" "$DST/$f"
  done
  ls -l "$DST" | head -40

  echo "== 1. 宿主机环境 =="
  uname -m; uname -r; nproc
  free -g | head -2
  df -h / /home | tail -3
  echo "-- taskset 绑核范围是否有效 --"
  taskset -c 0-15,128-143 true; echo "taskset 0-15,128-143 rc=$?"
  echo "-- 多流参数 --"
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null || echo "无参数文件"
  echo "-- GPU --"
  timeout 20 /usr/local/corex/bin/ixsmi 2>&1 | sed -n '1,12p;/Processes/,$p' | head -20
  echo "-- 占用与在跑进程 --"
  fuser -vm /dev/iluvatar* 2>&1 | head -5 || true
  pgrep -af 'vllm.entrypoints|ixsys|bench_driver' 2>/dev/null | head -5 || echo "无相关进程"
  echo "-- 容器 --"
  docker ps --filter name=corex5-py311 --format '{{.Names}}\t{{.Status}}'

  echo "== 2. 容器内能力（只读）=="
  docker exec -e PYTHONPATH= -e PYTHONHOME= corex5-py311 bash -lc '
    echo "-- python/venv --"
    /opt/corex311/bin/python3 -V
    ls -d /opt/corex311 /opt/corex311-cpython-vllm 2>&1
    /opt/corex311/bin/python3 - <<PY
import torch
print("torch", torch.__version__, "devices", torch.cuda.device_count())
PY
    echo "-- ixsys --"
    ls -l /usr/local/corex/bin/ixsys 2>&1
    /usr/local/corex/bin/ixsys --version 2>&1 | head -3
    echo "-- litehost 工具包 --"
    ls -l /home/qch/scripts/litehost_perf | head -40
    file /home/qch/scripts/litehost_perf/liblitehost.so 2>&1
    for f in procutil.py lhctl.py bench_driver.py light_host_worker.py analyze_litehost.py liblitehost.so; do
      [[ -e /home/qch/scripts/litehost_perf/$f ]] || echo "MISSING $f"
    done
    echo "-- 模型 --"
    ls /home/hc/modules/Qwen3-32B-W8A8 2>&1 | head -12
    du -sh /home/hc/modules/Qwen3-32B-W8A8 2>/dev/null
    echo "-- vllm 版本（信息）--"
    /opt/corex311/bin/python3 -c "import vllm;print(vllm.__version__, vllm.__file__)" 2>&1
    echo "-- mimalloc --"
    ls -l /home/ssh_t/mimalloc-3.6.1/build/libmimalloc.so.3.6 2>&1
    ls /usr/local/lib/libmimalloc* /usr/lib/libmimalloc* 2>&1 | head -5
    echo "-- 空间/端口 --"
    df -h /home | tail -1
    ss -ltn 2>/dev/null | grep -E ":8848|:8948" || echo "8848/8948 空闲"
    ls -la /home/qch/1125analysis 2>&1 | head -10
  '

  echo "== 3. 收尾 =="
  df -h /home | tail -1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
