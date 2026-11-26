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
  echo "### 本轮只读：只查磁盘占用与采集残留，不启动服务、不写、不删。"
  set +x

  echo
  echo "== 0. 空间 / 进程 =="
  df -h /home | tail -1
  pgrep -af '[d]river.sh' || echo "（没有 driver.sh）"
  pgrep -af '[v]llm.entrypoints.openai.api_server' || echo "（没有 vLLM）"
  pgrep -af '[/]usr/local/corex/bin/ixsys' || echo "（没有 ixsys）"

  echo
  echo "== 1. /home 一级目录占用 =="
  du -xsh /home/qch /home/hc /home/huawei_ts_program /home/ssh_t /home/model 2>/dev/null | sort -h

  echo
  echo "== 2. /home/qch 下各目录占用（前 20） =="
  du -xsh /home/qch/* 2>/dev/null | sort -h | tail -20

  echo
  echo "== 3. 1126analysis 内各目录 =="
  du -xsh /home/qch/1126analysis/* 2>/dev/null | sort -h

  echo
  echo "== 4. 本轮 e2e_traces 目录明细 =="
  ROOT=$(ls -dt /home/qch/1126analysis/*_e2e_traces 2>/dev/null | head -1)
  echo "ROOT=${ROOT:-（无）}"
  [[ -n "$ROOT" ]] && du -ah "$ROOT" 2>/dev/null | sort -h | tail -25

  echo
  echo "== 5. 大于 500M 的单个文件（/home，前 20） =="
  find /home -xdev -type f -size +500M -printf '%12s  %TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort -n | tail -20

  echo
  echo "== 6. 已删除但仍被进程占用的文件 =="
  if command -v lsof >/dev/null 2>&1; then
      lsof +L1 2>/dev/null | awk 'NR==1 || $7+0 > 100000000' | head -20
  else
      echo "（无 lsof）"
  fi

  echo
  echo "== 7. 容器内 /tmp 占用（如可见） =="
  docker exec corex5-py311 bash -lc 'df -h /tmp | tail -1; du -xsh /tmp/* 2>/dev/null | sort -h | tail -10' 2>/dev/null || echo "（未检查）"

  echo
  df -h /home | tail -1
  # ---- 命令结束 ----

} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
