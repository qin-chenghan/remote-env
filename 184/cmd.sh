#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 184 r14 安装失败复诊：PR1 的 cmake 用错 torch（命中了 /usr/local 的 3.12 包）。
# 先诊断，再在干净 env 下重试安装，最后 check + verify。
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
  C=corex5-py311
  W=/home/qch/transfer/r14
  D=$W/host-opt-pr-validation-20261106-r14
  V=/opt/corex311-cpython-vllm
  SP=$V/lib/python3.11/site-packages
  PY=$V/bin/python
  dex()  { timeout 180  docker exec "$C" bash -c "$1"; }
  dexl() { timeout 1800 docker exec "$C" bash -c "$1"; }

  echo "== 1. 服务占用检查 =="
  BUSY=$(timeout 60 docker exec "$C" bash -c "ps -eo args | grep -E 'vllm|benchmark|lhctl|api_server' | grep -v grep | head -5")
  if [ -n "$BUSY" ]; then echo "BUSY:"; echo "$BUSY"; echo "有服务在跑，终止"; exit 4; fi
  echo "无 vllm/bench 进程"

  echo "== 2. 当前安装状态（应仍是原厂：无备份、无 host_opt.py）=="
  dex "ls -ld $SP/.host-opt-pr-backup 2>&1"
  dex "ls -l $SP/vllm/v1/worker/host_opt.py $SP/vllm/v1/worker/compact_greedy_backport.py 2>&1"
  dex "grep -c VLLM_HOST_OPT_POSITIONS $SP/vllm/envs.py 2>/dev/null"

  echo "== 3. torch 导入诊断 =="
  dex "env | grep -E 'PYTHONPATH|PYTHONHOME|LD_PRELOAD' || echo '无 PYTHON* / LD_PRELOAD'"
  dex "$PY -c 'import sys;print(sys.version);print(sys.executable);print(sys.path)'"
  dex "env -u PYTHONPATH -u PYTHONHOME $PY -c 'import torch;print(torch.__version__, torch.__file__)'"
  echo "--- 带原环境导入（预期报错，复现故障）---"
  dex "$PY -c 'import torch;print(torch.__version__, torch.__file__)' 2>&1 | tail -5"
  echo "--- venv 内 torch 落地位置 ---"
  dex "ls -d $SP/torch/_C* 2>&1 | head -3; ls -l $SP/torch/_C/*.so 2>/dev/null | head -3"
  dex "ls -d /usr/local/lib/python3.12/site-packages/torch 2>&1"

  echo "== 4. 干净 env 下 dry-run =="
  dex "cd $D && env -u PYTHONPATH -u PYTHONHOME $PY scripts/install.py --root $SP --dry-run 2>&1 | tail -20"

  echo "== 5. 干净 env 下正式安装 =="
  dexl "cd $D && env -u PYTHONPATH -u PYTHONHOME $PY scripts/install.py --root $SP 2>&1 | tee $D/install-r14-clean.log | tail -30"
  RC=${PIPESTATUS[0]}
  echo "install rc=$RC"

  echo "== 6. check =="
  dex "cd $D && env -u PYTHONPATH -u PYTHONHOME $PY scripts/install.py --root $SP --check 2>&1 | tail -20"

  echo "== 7. verify =="
  dexl "cd $D && env -u PYTHONPATH -u PYTHONHOME $PY scripts/verify.py --root $SP 2>&1 | tail -25"

  echo "== 8. 安装后状态 =="
  dex "ls -ld $SP/.host-opt-pr-backup; ls $SP/.host-opt-pr-backup | head -3"
  dex "ls -l $SP/vllm/v1/worker/host_opt.py $SP/vllm/v1/worker/compact_greedy_backport.py 2>&1"
  echo -n "envs.py POSITIONS: "; dex "grep -c VLLM_HOST_OPT_POSITIONS $SP/vllm/envs.py"
  echo -n "compilation.py compact_greedy: "; dex "grep -c compact_greedy $SP/vllm/config/compilation.py"
  echo "--- 开关默认值（应全关）---"
  dex "env | grep VLLM_HOST_OPT || echo '未设置 VLLM_HOST_OPT*（默认关闭）'"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
