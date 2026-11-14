#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 只读：核对 vllmBench_lite_opt.sh 实际设的优化开关 vs venv 实际认的开关。
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
  C=corex5-py311
  D=/home/huawei_ts_program/litehost_perf_opt
  V=/opt/corex311-cpython-vllm
  SP=$V/lib/python3.11/site-packages/vllm
  dex() { timeout 60 docker exec "$C" bash -c "$1"; }

  echo "== 1. 脚本全文 =="
  cat "$D/vllmBench_lite_opt.sh"

  echo "== 2. 脚本里引用的库文件是否存在 =="
  for f in "$D/liblitehost.so" "$D/lhctl.py" "$D/analyze_litehost.py"; do ls -l "$f" 2>&1; done
  find /home -maxdepth 4 -name 'libtcmalloc.so*' 2>/dev/null | head -5

  echo "== 3. venv 认可的 VLLM_HOST_OPT 开关 =="
  dex "grep -n 'VLLM_HOST_OPT' $SP/envs.py | head -20"
  echo "--- host_opt.py 的门控逻辑 ---"
  dex "grep -nE 'VLLM_HOST_OPT|environ|getenv|enabled|ARENA|INPUTS|BOOKKEEPING|POSITIONS' $SP/v1/worker/host_opt.py | head -40"

  echo "== 4. compact_greedy 在 venv 里的开关方式 =="
  dex "grep -n 'compact_greedy' $SP/config/compilation.py | head -10"
  dex "grep -rn 'VLLM_COMPACT_GREEDY' $SP 2>/dev/null | head -5 || echo '无该环境变量'"

  echo "== 5. 当前驱动多流参数 =="
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null

  echo "== 6. venv 版本与 r14 落盘 =="
  dex "ls -ld $SP/.host-opt-pr-backup; grep -oE 'VLLM_HOST_OPT[A-Z_]*' $SP/envs.py | sort -u"
  dex "$V/bin/python -c 'import vllm;print(vllm.__version__)'"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
