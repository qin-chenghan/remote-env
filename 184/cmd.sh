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
  # 184 的 opt 脚本切到 r10 开关：VLLM_HOST_OPT* + compact greedy + sample logits 配置。
  # 备份、语法检查、容器内 dry-run 验证。

  D=/home/huawei_ts_program/litehost_perf_opt
  F=$D/vllmBench_lite_opt.sh
  TS2=$(date +%Y%m%d-%H%M%S)

  echo "== 0. 备份 =="
  cp -a "$F" "$F.bak-r10-$TS2" && echo "backup $F.bak-r10-$TS2"

  echo "== 1. 改开关与编译配置 =="
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

old_env = """SERVER_EXTRA_ENV=(
    UMD_MAXCOMMANDBUFFERNUMBER=256
    UMD_MAXCOMMANDBUFFERSIZE=16384
    VLLM_HOST_FASTPATH=on
    TORCH_MODULE_ATTR_FASTPATH=slot_native
)"""
new_env = """SERVER_EXTRA_ENV=(
    UMD_MAXCOMMANDBUFFERNUMBER=256
    UMD_MAXCOMMANDBUFFERSIZE=16384
    VLLM_HOST_OPT=on
    VLLM_HOST_OPT_INPUTS=on
    VLLM_HOST_OPT_ARENA=on
    VLLM_HOST_OPT_BOOKKEEPING=on
    VLLM_HOST_OPT_METADATA=on
    VLLM_HOST_OPT_DIAGNOSTICS=0
    VLLM_COMPACT_GREEDY=on
    VLLM_COMPACT_GREEDY_DIAGNOSTICS=0
    TORCH_MODULE_ATTR_FASTPATH=slot_native
)"""
if old_env not in s:
    raise SystemExit("FAIL: env block not found")
s = s.replace(old_env, new_env, 1)

old_cc = """--compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY", "mode":0}'"""
new_cc = """--compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY", "mode":0, "sample_logits_cudagraph":"on", "sample_logits_cudagraph_max_bytes":67108864, "sample_logits_cudagraph_capture_sizes":[1,2,3,4,5,6,7,8]}'"""
if old_cc not in s:
    raise SystemExit("FAIL: compilation-config line not found")
s = s.replace(old_cc, new_cc, 1)

open(p, "w").write(s)
print("updated", p)
PY

  echo "== 2. 语法检查 =="
  bash -n "$F" && echo "OK opt"

  echo "== 3. diff =="
  diff -u "$F.bak-r10-$TS2" "$F" | head -60

  echo "== 4. 容器内 dry-run =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= corex5-py311 bash -c \
    "cd $D && HOST_DRY_RUN=1 bash vllmBench_lite_opt.sh" 2>&1 | grep -E "PREFIX=|SERVER:|CASES:|ERROR" | head -5

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
