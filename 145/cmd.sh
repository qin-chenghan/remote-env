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
  # 构建 libpreprocess.so 并跑仓库自带基准（占位基线）。

  echo "== 1. 仓库状态 =="
  docker exec fusionv1 bash -lc '
P=/home/qch/projects
ls -d "$P" 2>&1
git -C "$P" rev-parse --abbrev-ref HEAD 2>&1
git -C "$P" log --oneline -3 2>&1
ls -l "$P/workplace/lib_preprocess.cpp" 2>&1
' 2>&1 | head -20

  echo "== 2. 工具链与 python 依赖 =="
  docker exec fusionv1 bash -lc '
g++ --version | head -1
python3 -V
python3 -c "import numpy, PIL; print(\"numpy\", numpy.__version__, \"PIL\", PIL.__version__)" 2>&1 | tail -2
' 2>&1 | head -10

  echo "== 3. 构建 libpreprocess.so =="
  docker exec fusionv1 bash -lc '
cd /home/qch/projects/workplace || exit 1
ls -l libpreprocess.so 2>&1
g++ -std=c++14 -march=armv8.2-a+fp16+dotprod -fopenmp -O3 \
    -shared -fPIC -o libpreprocess.so lib_preprocess.cpp 2>&1 | tail -20
echo "build rc=$?"
ls -l libpreprocess.so 2>&1
' 2>&1 | head -25

  echo "== 4. 正确性（e2e_verify）=="
  docker exec fusionv1 bash -lc '
cd /home/qch/projects/workplace/edition1 || exit 1
timeout 300 python3 e2e_verify.py 2>&1 | tail -25
' 2>&1 | head -30

  echo "== 5. 分步耗时（224×224, 1 线程）=="
  docker exec fusionv1 bash -lc '
cd /home/qch/projects/workplace/edition1 || exit 1
timeout 300 python3 step_breakdown.py --size 224 224 --threads 1 --iters 100 2>&1 | tail -30
' 2>&1 | head -35

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
