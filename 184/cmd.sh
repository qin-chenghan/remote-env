#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 取回 vllmBench_lite_timeline.sh 全文，并与现有 bench 脚本对比时效性。
# 纯 CPU，不启动 vllm，不动 GPU。
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
  echo "== 0. 所有 vllmBench_lite* 脚本（按修改时间） =="
  find /home -maxdepth 4 -name 'vllmBench_lite*.sh' -printf '%TY-%Tm-%Td %TH:%TM %10s  %p\n' 2>/dev/null | sort

  echo "== 1. 目标脚本 stat + sha256 =="
  for f in /home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh \
           /home/qch/scripts/litehost_perf/vllmBench_lite_opt.sh \
           /home/qch/scripts/litehost_perf/vllmBench_lite_base.sh \
           /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh \
           /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_timeline.sh ; do
    if [ -f "$f" ]; then
      stat -c '%n  mtime=%y  size=%s' "$f"
      sha256sum "$f"
    else
      echo "MISSING  $f"
    fi
  done

  echo "== 2. vllmBench_lite_timeline.sh 全文 (/home/qch/scripts/litehost_perf) =="
  if [ -f /home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh ]; then
    cat -n /home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh
  else
    echo "MISSING"
  fi

  echo "== 3. 与 vllmBench_lite_opt.sh 的差异 (/home/qch/scripts/litehost_perf) =="
  if [ -f /home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh ] && \
     [ -f /home/qch/scripts/litehost_perf/vllmBench_lite_opt.sh ]; then
    diff -u /home/qch/scripts/litehost_perf/vllmBench_lite_opt.sh \
            /home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh
    echo "  (diff exit=$?)"
  fi

  echo "== 4. 与 11-14 实际使用的 vllmBench_lite_opt.sh 的差异 (/home/huawei_ts_program) =="
  if [ -f /home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh ] && \
     [ -f /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh ]; then
    diff -u /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh \
            /home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh
    echo "  (diff exit=$?)"
  fi

  echo "== 5. 副本之间是否一致 =="
  diff -q /home/qch/scripts/litehost_perf/vllmBench_lite_opt.sh \
          /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh \
    && echo "  两份 vllmBench_lite_opt.sh 完全相同" \
    || echo "  两份 vllmBench_lite_opt.sh 不同"

  echo "== 6. 关键开关：timeline 脚本里有没有 =="
  T=/home/qch/scripts/litehost_perf/vllmBench_lite_timeline.sh
  for pat in compact_greedy sample_logits_cudagraph_scope sample_logits_cudagraph \
             no-enable-prefix-caching VLLM_COMPACT_GREEDY \
             VLLM_HOST_OPT_POSITIONS VLLM_HOST_OPT_METADATA VLLM_HOST_OPT_INPUTS \
             VLLM_HOST_OPT_ARENA VLLM_HOST_OPT_BOOKKEEPING \
             TORCH_MODULE_ATTR_FASTPATH UMD_MAXCOMMANDBUFFER TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES \
             liblitehost light_host_worker profiler-config profiler_config \
             taskset CPU_RANGE PREFIX= PORT= NUM_PROMPTS NUM_WARMUPS MAX_CONCURRENCY ; do
    n=$(grep -c -- "$pat" "$T" 2>/dev/null || true)
    printf '  %-38s %s\n' "$pat" "${n:-0}"
  done

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
