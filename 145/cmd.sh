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
  # 在宿主机新建 /home/qch/clamp_opt，编译基线 .so，复用仓库自带的三个 python 脚本。
  # 仓库本身不修改（脚本是复制过来的副本）。

  D=/home/qch/clamp_opt
  R=/home/qch/projects/vllm/workplace

  echo "== 1. 宿主机工具链 =="
  g++ --version 2>&1 | head -1
  python3 -V
  ls /usr/lib64/libgomp.so* /usr/lib/aarch64-linux-gnu/libgomp.so* 2>/dev/null | head -3

  echo "== 2. 准备新目录 =="
  mkdir -p "$D/edition1"
  ls -la "$D" | head -5

  echo "== 3. 复制基准脚本（副本，不改原文件）=="
  cp -a "$R/edition1/bench_all.py" "$R/edition1/e2e_verify.py" "$R/edition1/step_breakdown.py" "$D/edition1/" 2>&1
  ls -l "$D/edition1"

  echo "== 4. 编译基线 .so（输出按脚本期望放在 $D/libpreprocess.so）=="
  g++ -std=c++14 -march=armv8.2-a+fp16+dotprod -fopenmp -O3 \
      -shared -fPIC -o "$D/libpreprocess.so" "$R/lib_preprocess.cpp" 2>&1 | tail -10
  echo "build rc=$?"
  ls -l "$D/libpreprocess.so"
  ldd "$D/libpreprocess.so" 2>&1 | grep -i "not found" | head -5

  echo "== 5. 正确性验证（e2e_verify）=="
  cd "$D/edition1" && taskset -c 0-3 python3 e2e_verify.py 2>&1 | tail -20

  echo "== 6. 分步耗时（224×224, 1 线程）=="
  cd "$D/edition1" && taskset -c 0 python3 step_breakdown.py --size 224 224 --threads 1 --iters 100 2>&1 | tail -25

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
