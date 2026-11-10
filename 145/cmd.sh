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
  # 只读：在容器 fusionv1 内定位工作区与目标 cpp。

  echo "== 1. workspace 顶层 =="
  docker exec fusionv1 bash -lc '
    ls -la /home/workspace 2>&1 | head -15
    echo "-- tensor --"
    ls -la /home/workspace/tensor 2>&1 | head -20
    echo "-- tensor/files --"
    ls /home/workspace/tensor/files 2>&1 | head -30
  ' 2>&1 | head -70

  echo "== 2. 找目标目录 =="
  docker exec fusionv1 bash -lc '
    find /home/workspace -maxdepth 4 -type d -name "*opt_fusion*" 2>/dev/null | head -10
    find /home/workspace -maxdepth 5 -type f -name "pillow_fusion_func_v2.cpp" 2>/dev/null | head -10
  ' 2>&1 | head -20

  echo "== 3. 目标目录内容 =="
  docker exec fusionv1 bash -lc '
    W=$(find /home/workspace -maxdepth 4 -type d -name "*opt_fusion*" 2>/dev/null | head -1)
    echo "W=$W"
    [ -n "$W" ] && ls -la "$W" | head -25
    [ -n "$W" ] && du -sh "$W"
  ' 2>&1 | head -40

  echo "== 4. 目标文件 =="
  docker exec fusionv1 bash -lc '
    F=$(find /home/workspace -maxdepth 5 -type f -name "pillow_fusion_func_v2.cpp" 2>/dev/null | head -1)
    echo "F=$F"
    if [ -n "$F" ]; then
      wc -l "$F"; head -70 "$F"
    fi
  ' 2>&1 | head -85

  echo "== 5. 构建与依赖 =="
  docker exec fusionv1 bash -lc '
    W=$(find /home/workspace -maxdepth 4 -type d -name "*opt_fusion*" 2>/dev/null | head -1)
    [ -n "$W" ] && ls -la "$W" | grep -iE "CMakeLists|Makefile|setup.py|requirements|build|test|README" | head -15
    echo "-- 上层目录 --"
    [ -n "$W" ] && ls -la "$(dirname "$W")" | head -20
  ' 2>&1 | head -40

  echo "== 6. 其他 python 环境 =="
  docker exec fusionv1 bash -lc '
    ls /opt 2>/dev/null | head -10
    command -v conda || echo no-conda
    python3 -c "import sys;print(sys.executable)" 2>&1
    python3 -m pip --version 2>&1 | head -2
  ' 2>&1 | head -20

  echo "== 7. 容器 resource limits =="
  docker inspect fusionv1 --format '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{json .HostConfig.CpusetCpus}}' 2>&1

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
