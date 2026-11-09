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
  # 无待执行指令；本批仅输出当前状态快照（只读）。

  CON=corex5-py311
  BASE=/opt/corex311
  NEW=/opt/corex311-cpython-vllm
  D=/home/huawei_ts_program/litehost_perf_opt

  echo "== 1. 两个 venv =="
  docker exec "$CON" sh -c "
for V in $BASE $NEW; do
  echo \"-- \$V\"
  if [ -x \$V/bin/python ]; then
    \$V/bin/python -c 'import sys,sysconfig; print(\"  prefix\", sys.prefix); print(\"  base_prefix\", sys.base_prefix); print(\"  pgo\", \"--prefix=/opt/cpython-vllm/v1\" in (sysconfig.get_config_var(\"CONFIG_ARGS\") or \"\"))' 2>/dev/null
    echo -n '  packages: '; \$V/bin/python -m pip freeze --all 2>/dev/null | wc -l
  else
    echo '  missing'
  fi
done
"

  echo "== 2. bench 脚本是否仍含 rebase 切换 =="
  for f in "$D/vllmBench_lite_base.sh" "$D/vllmBench_lite_opt.sh"; do
    echo "-- $f"
    if [ -f "$f" ]; then
      echo -n "  pgo_switch/rollback 引用数: "
      grep -c "pgo_switch\|pgo_rollback" "$f" || true
      grep -n "PREFIX=\|runtime:" "$f" | head -4
    else
      echo "  missing"
    fi
  done

  echo "== 3. 当前是否有 bench/vllm 在跑 =="
  pgrep -af "vllmBench|bench_driver|vllm.entrypoints|api_server" 2>/dev/null | grep -v pgrep | head -6 || echo "无"

  echo "== 4. 磁盘 =="
  docker exec "$CON" sh -c 'du -sh /opt/corex311 /opt/corex311-cpython-vllm 2>/dev/null; df -h /opt | tail -1'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
