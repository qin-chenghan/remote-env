#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：全量扫描 184 上的 vllmBench_lite 脚本配置，并对照本机环境校验。
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
  echo "== 本机环境基准 =="
  echo "-- NUMA --"
  numactl -H 2>/dev/null | grep -E 'node [0-9] cpus|node [0-9] size' | sed 's/node \([0-9]\) cpus:/node \1 CPUs:/'
  echo "-- GPU NUMA --"
  for b in 0000:45:00.0 0000:48:00.0 0000:af:00.0 0000:b2:00.0; do
    printf '  %s node=%s\n' "$b" "$(cat /sys/bus/pci/devices/$b/numa_node 2>/dev/null)"
  done
  echo "-- 路径存在性 --"
  for p in /home/model/Qwen3-32B-W8A8 /opt/corex311-cpython-vllm /opt/corex311 \
           /home/lw/gperftools/.libs/libtcmalloc.so /home/huawei_ts_program/litehost_perf_opt/liblitehost.so; do
    [ -e "$p" ] && echo "  OK   $p" || echo "  MISS $p"
  done

  echo ""
  echo "== vllmBench_lite 脚本清单 =="
  find /home -maxdepth 5 -name 'vllmBench_lite*.sh' 2>/dev/null | while read -r f; do echo "  $(stat -c '%y' "$f" | cut -d. -f1)  $(stat -c %s "$f")  $f"; done | sort -r | head -12

  echo ""
  for f in $(find /home -maxdepth 5 -name 'vllmBench_lite_*.sh' 2>/dev/null | while read -r x; do echo "$(stat -c %Y "$x") $x"; done | sort -rn | head -6 | cut -d' ' -f2-); do
    echo "################ $f ################"
    echo "-- 基础配置 --"
    grep -nE '^(MODEL_PATH|TEST_ID|PREFIX|PYTHON_BIN|GPU_LIST|GPUS_PER_INSTANCE|PORT|NUM_PROMPTS|NUM_WARMUPS|MAX_CONCURRENCY|CASE_INTERVAL|CPU_RANGE|ENABLE_TASKSET|HOST_MEASURE|HOST_TOOLKIT)=' "$f" | cut -c1-150
    echo "-- 依赖路径 --"
    grep -nE 'libtcmalloc|liblitehost|gperftools|LIGHTHOST|PYTHONPATH=' "$f" | cut -c1-150 | head -8
    echo "-- CLEAN_ENV --"
    grep -nA2 'CLEAN_ENV=(env' "$f" | cut -c1-150 | head -4
    echo "-- r10 / 开关 --"
    grep -nE 'VLLM_HOST_OPT|VLLM_COMPACT_GREEDY|TORCH_MODULE_ATTR|UMD_MAX|worker-cls|compilation-config|sample_logits' "$f" | cut -c1-170 | head -14
    echo "-- 启用的用例 --"
    awk '/CASES=\(/,/^ *\)/' "$f" | grep -E '^[[:space:]]*"[0-9]+ [0-9]+"' | cut -c1-100
    echo "-- 可疑项 --"
    grep -nE '192-255|2403|oe2403|/home/z30059427|/home/s00806700|timeline' "$f" | cut -c1-150 | head -6
    echo ""
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
