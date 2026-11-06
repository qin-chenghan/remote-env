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

  echo "== os =="
  uname -a
  head -3 /etc/os-release 2>/dev/null

  echo "== container =="
  cat /proc/1/cgroup 2>/dev/null | head -5
  ls -d /opt/* 2>/dev/null

  echo "== python/venv =="
  /opt/corex311/bin/python -V 2>&1
  /opt/corex311-cpython-vllm/bin/python -V 2>&1
  /opt/corex311-cpython-vllm/bin/pip list 2>/dev/null | grep -iE '^(vllm|torch|ixsys|triton)' | head

  echo "== gpu =="
  for c in ixsmi ix-smi nvidia-smi; do
    command -v "$c" >/dev/null && { echo "found: $c"; "$c" 2>&1 | head -40; break; }
  done

  echo "== topo =="
  command -v nvidia-smi >/dev/null && nvidia-smi topo -m 2>&1 | head -30

  echo "== cpu/numa =="
  lscpu 2>/dev/null | head -30
  command -v numactl >/dev/null && numactl -H 2>&1 | head -30

  echo "== mem/disk =="
  free -g 2>/dev/null
  df -h /home /opt 2>/dev/null

  echo "== env =="
  echo "LD_PRELOAD=${LD_PRELOAD:-<empty>}"
  echo "VIRTUAL_ENV=${VIRTUAL_ENV:-<empty>}"
  echo "PATH=$(echo "$PATH" | tr ':' '\n' | head -15)"

  echo "== repo =="
  ls -la /home/qch/tools/remote-env 2>&1 | head
  git -C /home/qch/tools/remote-env log --oneline -3 2>&1
  git -C /home/qch/tools/remote-env status --short 2>&1 | head

  echo "== perf-opt =="
  ls -la /home/huawei_ts_program/litehost_perf_opt 2>&1 | head -20

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
