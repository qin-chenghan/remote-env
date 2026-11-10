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
  # 把 vllmBench_lite_taskset.sh 改名为 vllmBench_lite_base.sh，
  # 默认 MODEL_PATH 与 buffer 环境变量向 184/32 对齐。

  D=/home/qch/scripts/litehost_perf
  OLD=$D/vllmBench_lite_taskset.sh
  NEW=$D/vllmBench_lite_base.sh
  BAK=$D/vllmBench_lite_taskset.sh.bak-$TS

  echo "== 1. 备份并改名 =="
  ls -l "$OLD" "$NEW" 2>&1
  cp -a "$OLD" "$BAK"
  mv "$OLD" "$NEW"
  ls -l "$NEW" "$BAK"

  echo "== 2. 修改内容 =="
  python3 - "$NEW" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

edits = [
    # 模型路径：从强制外部传入改为带默认值（与 184 同构，路径按 203 实际）
    (': "${MODEL_PATH:?ERROR: 必须设置 MODEL_PATH}"',
     'MODEL_PATH="${MODEL_PATH:-/home/models/Qwen3-32B-W8A8}"'),
    # 加 buffer 环境变量（与 184 取值一致）
    ('SERVER_PREFIX=()',
     'SERVER_EXTRA_ENV=(\n'
     '    UMD_MAXCOMMANDBUFFERNUMBER=256\n'
     '    UMD_MAXCOMMANDBUFFERSIZE=16384\n'
     ')\n'
     'SERVER_PREFIX=()'),
    # 把 buffer 注入到服务启动环境
    ('env_args=(CUDA_VISIBLE_DEVICES="$GPU_LIST" VLLM_ENFORCE_CUDA_GRAPH=1 VLLM_USE_V1=1)',
     'env_args=(CUDA_VISIBLE_DEVICES="$GPU_LIST" VLLM_ENFORCE_CUDA_GRAPH=1 VLLM_USE_V1=1 "${SERVER_EXTRA_ENV[@]}")'),
    # 顶部注释对齐实际默认值
    ('# Defaults retained: warmups=16, cache OFF, CPUs 80-159,240-319, backend=vllm.',
     '# Defaults retained: warmups=16, cache OFF, CPUs 0-15,128-143 (NUMA0), backend=vllm,\n'
     '# UMD buffers 256/16384, MODEL_PATH=/home/models/Qwen3-32B-W8A8.'),
]

for old, new in edits:
    if old not in s:
        raise SystemExit(f"FAIL: pattern not found -> {old[:60]}")
    s = s.replace(old, new, 1)

open(p, "w").write(s)
print("patched", p)
PY
  echo "patch rc=$?"

  echo "== 3. 语法检查与差异 =="
  bash -n "$NEW" && echo "syntax OK"
  grep -n 'MODEL_PATH=\|SERVER_EXTRA_ENV\|UMD_MAXCOMMANDBUFFER\|VLLM_USE_V1=1' "$NEW" | head -12
  diff -u "$BAK" "$NEW" | head -60

  echo "== 4. 容器内 dry-run（打印实际启动命令）=="
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e VIRTUAL_ENV= \
    -e MODEL_PATH=/home/models/Qwen3-32B-W8A8 \
    -e HOST_MEASURE=off -e HOST_DRY_RUN=1 \
    corex5-py311 bash -lc '
      cd /home/qch/scripts/litehost_perf && bash vllmBench_lite_base.sh
    ' 2>&1 | head -20

  echo "== 5. 确认 buffer 注入点 =="
  sed -n '/SERVER_EXTRA_ENV=(/,/^)/p' "$NEW"
  grep -n 'env_args=(' "$NEW"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
