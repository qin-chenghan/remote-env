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
  # 只读：了解 145 的宿主、容器 fusionv1、目标工作区与构建工具链。

  echo "== 1. 宿主 =="
  uname -a
  head -4 /etc/os-release
  lscpu 2>/dev/null | grep -E 'Model name|CPU\(s\)|Socket|Thread|NUMA node' | head -8
  free -g 2>/dev/null | head -2

  echo "== 2. 容器的存在性 =="
  for r in docker podman nerdctl; do
    command -v "$r" >/dev/null || continue
    echo "runtime: $r"
    "$r" ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1 | head -15
  done

  echo "== 3. fusionv1 概况 =="
  docker inspect fusionv1 --format '{{.State.Status}} started={{.State.StartedAt}} image={{.Config.Image}}' 2>&1
  docker inspect fusionv1 --format '{{range .HostConfig.Binds}}{{.}}{{"\n"}}{{end}}' 2>&1 | head -10
  docker exec fusionv1 bash -lc 'echo "host: $(hostname)"; echo "user: $(id -un)"; echo "pwd: $(pwd)"; ls /home/workspace 2>&1 | head -10' 2>&1 | head -20

  echo "== 4. 目标工作区目录 =="
  W=/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro
  ls -la "$W" 2>&1 | head -30
  echo "-- 目录规模 --"
  du -sh "$W" 2>&1
  find "$W" -maxdepth 2 -type f 2>/dev/null | head -20

  echo "== 5. 目标文件 =="
  F=$W/pillow_fusion_func_v2.cpp
  ls -l "$F" 2>&1
  wc -l "$F" 2>&1
  head -60 "$F" 2>&1

  echo "== 6. 容器内工具链 =="
  docker exec fusionv1 bash -lc '
    for c in gcc g++ clang make cmake ninja python python3 pip git; do
      printf "%-8s " "$c"; command -v "$c" || echo missing
    done
    gcc --version 2>/dev/null | head -1
    cmake --version 2>/dev/null | head -1
    python3 -V 2>&1
    nproc
  ' 2>&1 | head -30

    echo "== 7. 容器内 python 包（与算子/融合相关）=="
  docker exec fusionv1 bash -lc '
    python3 -m pip list 2>/dev/null | grep -iE "torch|triton|numpy|pillow|transformers|vllm|flash|apex|cupy" | head -15
  ' 2>&1 | head -20

  echo "== 8. 是否 git 仓库 =="
  git -C "$W" rev-parse --is-inside-work-tree 2>&1 | head -3
  git -C "$W" log --oneline -3 2>&1 | head -5
  git -C "$W" status --short 2>&1 | head -10

  echo "== 9. 用户目录与仓库 =="
  ls /home/qch 2>&1 | head -15
  ls -d /home/qch/tools/remote-env 2>&1

  echo "== 10. 磁盘 =="
  df -h / /home 2>&1 | tail -3

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
