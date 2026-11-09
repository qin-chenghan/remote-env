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
  # 清理 184 两个 bench 脚本里剩余的 PGO 残留：注释、pgo_runtime/pgo_is_on、config.txt 的 pgo 行。
  # 有 bench/vllm 进程在跑则中止；改前备份，改后 bash -n + grep + diff。

  D=/home/huawei_ts_program/litehost_perf_opt
  TS2=$(date +%Y%m%d-%H%M%S)

  echo "== 0. 占用检查 =="
  BUSY=$(pgrep -af "vllmBench|bench_driver|vllm.entrypoints|api_server" 2>/dev/null | grep -v "pgrep\|cmd.sh" || true)
  if [ -n "$BUSY" ]; then
    echo "ABORT: 有任务在跑："
    echo "$BUSY" | head -5
    exit 1
  fi
  echo "无 bench/vllm 进程"

  echo "== 1. 备份并清理 =="
  python3 - "$D" "$TS2" <<'PYPATCH'
import os, shutil, sys

D, TS = sys.argv[1], sys.argv[2]
CONFIG_OLD = '    echo "pgo=$(pgo_is_on && echo on || echo off)"\n'
CONFIG_NEW = '    echo "prefix=$PREFIX"\n'
TRAP_OLD = "trap 'exit 143' TERM\n\ncheck_gpu_memory() {"
TRAP_NEW = "trap 'exit 143' TERM\n\nlog \"PREFIX=$PREFIX\"\n\ncheck_gpu_memory() {"

def patch(name):
    p = os.path.join(D, name)
    s = open(p, encoding="utf-8").read()
    orig = s

    start = s.index("# ---- runtime check: read-only")
    end = s.index("SERVER_PREFIX=()")
    if not (0 < start < end):
        raise SystemExit(f"FAIL {name}: region markers not found")
    s = s[:start] + s[end:]

    if CONFIG_OLD not in s:
        raise SystemExit(f"FAIL {name}: config pgo line not found")
    s = s.replace(CONFIG_OLD, CONFIG_NEW)

    if TRAP_OLD not in s:
        raise SystemExit(f"FAIL {name}: trap anchor not found")
    s = s.replace(TRAP_OLD, TRAP_NEW)

    bad = [ln for ln in s.splitlines() if "pgo" in ln.lower() or "rebase" in ln.lower()]
    if bad:
        raise SystemExit(f"FAIL {name}: leftover refs: {bad}")

    shutil.copy2(p, f"{p}.bak-{TS}")
    open(p, "w", encoding="utf-8").write(s)
    print(f"PATCHED {p} ({len(orig)} -> {len(s)} bytes, backup .bak-{TS})")

patch("vllmBench_lite_base.sh")
patch("vllmBench_lite_opt.sh")
PYPATCH

  echo "== 2. 语法检查 =="
  bash -n "$D/vllmBench_lite_base.sh" && echo "OK base" || echo "SYNTAX ERROR base"
  bash -n "$D/vllmBench_lite_opt.sh" && echo "OK opt" || echo "SYNTAX ERROR opt"

  echo "== 3. 确认无 pgo/rebase =="
  grep -in "pgo\|rebase" "$D/vllmBench_lite_base.sh" "$D/vllmBench_lite_opt.sh" || echo "(无)"

  echo "== 4. diff（备份 -> 新）=="
  for f in vllmBench_lite_base.sh vllmBench_lite_opt.sh; do
    echo "---- $f"
    diff -u "$D/$f".bak-$TS2 "$D/$f" | head -60
  done

  echo "== 5. 关键行 =="
  grep -n "PREFIX=\|VLLM_HOST_FASTPATH\|TORCH_MODULE_ATTR\|VLLM_DISABLE_DECODE\|log \"PREFIX\|prefix=" \
    "$D/vllmBench_lite_base.sh" "$D/vllmBench_lite_opt.sh" | head -12

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
