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
  echo "### 本轮只读：不启动服务、不写、不删；只查 e2e_traces 采集进度与 trace 完整性。"
  set +x

  echo
  echo "== 0. 空间 / 进程 / 端口 =="
  df -h /home | tail -1
  pgrep -af '[d]river.sh' || echo "（没有 driver.sh 在跑）"
  pgrep -af '[v]llm.entrypoints.openai.api_server' || echo "（没有 vLLM 服务）"
  pgrep -af '[/]usr/local/corex/bin/ixsys' || echo "（没有 ixsys）"
  ss -ltn 2>/dev/null | awk '$4 ~ /:8848$/' || true

  echo
  echo "== 1. 最新的 e2e_traces 目录 =="
  ROOT=$(ls -dt /home/qch/1126analysis/*_e2e_traces 2>/dev/null | head -1)
  if [[ -z "$ROOT" ]]; then
      echo "!! 没有找到 /home/qch/1126analysis/*_e2e_traces"
      echo "（若驱动还没启动，确认 git pull 后是否执行了上一版 203/cmd.sh）"
  else
      echo "ROOT=$ROOT"
      ls -la "$ROOT" | head -20
      echo
      echo "-- driver.pid --"
      cat "$ROOT/driver.pid" 2>/dev/null || echo "（无 pid 文件）"
      echo "-- driver.log 大小/最后修改 --"
      ls -l "$ROOT/driver.log" 2>/dev/null
      echo
      echo "-- 完成/失败标记 --"
      grep -nE 'DRIVER_DONE|!!!!!|STOP|FATAL' "$ROOT/driver.log" 2>/dev/null | tail -20 || echo "（还没有完成或失败标记）"
      echo
      echo "-- 每个 case 的 trace 校验行 --"
      grep -nE 'trace 校验|OK ->|FAILED' "$ROOT/driver.log" 2>/dev/null | tail -30 || true
      echo
      echo "-- driver.log 末尾 60 行 --"
      tail -60 "$ROOT/driver.log" 2>/dev/null

      echo
      echo "== 2. 已产出的 trace / summary =="
      for kind in timeline ixsys; do
          for d in "$ROOT/$kind"/*/; do
              [[ -d "$d" ]] || continue
              echo "-- $d --"
              find "$d" -type f \( -name '*.ptrace' -o -name '*.ptrace-journal' -o -name '*.json.gz' -o -name '*.json' \) \
                  -printf '%12s  %p\n' 2>/dev/null | sort -k2
              [[ -f "$d/summary.csv" ]] && tail -n +2 "$d/summary.csv" | cut -d, -f1-9
          done
      done

      echo
      echo "== 3. 未搬进正式目录的 .work_*（失败/进行中） =="
      find "$ROOT" -maxdepth 1 -name '.work_*' -type d -printf '%p\n' 2>/dev/null | while read -r w; do
          echo "-- $w --"
          du -sh "$w" 2>/dev/null
          find "$w" -name '*.ptrace' -printf '%12s  %p\n' 2>/dev/null | head -5
          find "$w" -name 'server.log' -printf '%12s  %p\n' 2>/dev/null | head -3
      done
  fi

  echo
  df -h /home | tail -1
  # ---- 命令结束 ----

} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
