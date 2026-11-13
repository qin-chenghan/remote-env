#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 定位 bench_driver 的所有副本，只给这次 run 用的那份加失败原因落盘（先备份、再语法校验、打印 diff）。
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
  T=/home/huawei_ts_program/litehost_perf_opt/bench_driver.py

  echo "== 1. 所有 bench_driver.py 副本 =="
  find /home -maxdepth 4 -name 'bench_driver.py' 2>/dev/null | while read -r f; do
    echo "---- $f"
    ls -l --time-style=long-iso "$f"
    sha256sum "$f"
  done

  echo "== 2. 各套 toolkit 目录与脚本 =="
  find /home -maxdepth 3 -name 'lh_common.py' 2>/dev/null | head -10
  ls -l --time-style=long-iso /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite*.sh 2>/dev/null

  echo "== 3. 这次 run 用的那份：end() 现状 =="
  grep -n "async def end" -A 4 "$T"

  echo "== 4. 服务占用检查（改源码前确认没人正在用这份驱动）=="
  ps -eo pid,args 2>/dev/null | grep -E 'bench_driver|vllm' | grep -v grep | head -5 || echo "无相关进程"

  echo "== 5. 备份 + 打补丁 =="
  BAK="$T.bak-failed-errors-$TS"
  if grep -q 'failed_errors' "$T" 2>/dev/null; then
    echo "已含 failed_errors，跳过"
  else
    cp -a "$T" "$BAK" && echo "backup=$BAK"
    python3 - "$T" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
old = "        if len(outputs)!=self.case['expected_requests'] or not all(o.success for o in outputs):raise RuntimeError('Formal requests incomplete/failed; no valid H')"
new = (
"        if len(outputs)!=self.case['expected_requests'] or not all(o.success for o in outputs):\n"
"            self.window['failed_errors']=[{'i':i,'error':str(getattr(o,'error',''))[:300]} for i,o in enumerate(outputs) if not o.success][:10]\n"
"            self.save()\n"
"            raise RuntimeError('Formal requests incomplete/failed; no valid H')"
)
if old not in src:
    print('PATTERN_NOT_FOUND: 未找到原始判定行，未修改'); sys.exit(3)
open(p,'w').write(src.replace(old, new, 1))
print('PATCHED')
PY
    echo "patch rc=$?"
  fi

  echo "== 6. 语法校验与 diff =="
  python3 -m py_compile "$T" && echo "py_compile OK"
  diff -u "$BAK" "$T" 2>/dev/null | head -30
  grep -n "failed_errors" -A 3 "$T" | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
