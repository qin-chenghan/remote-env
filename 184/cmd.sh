#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 安装 r14 三补丁到 /opt/corex311-cpython-vllm（先卸载旧的、备份、dry-run、check、verify）。
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
  Z=/home/qch/transfer/host-opt-three-pr-validation-r14-arm64-py311-20261112.zip
  W=/home/qch/transfer/r14
  D=$W/host-opt-pr-validation-20261106-r14
  V=/opt/corex311-cpython-vllm
  SP=$V/lib/python3.11/site-packages
  PY=$V/bin/python
  dex()  { timeout 120  docker exec "$C" bash -c "$1"; }
  dexl() { timeout 1800 docker exec "$C" bash -c "$1"; }

  echo "== 1. 服务占用检查 =="
  BUSY=$(timeout 60 docker exec "$C" bash -c "ps -eo args | grep -E 'vllm|benchmark|lhctl|api_server' | grep -v grep | head -5")
  if [ -n "$BUSY" ]; then echo "BUSY:"; echo "$BUSY"; echo "有服务在跑，终止安装"; exit 4; fi
  echo "无 vllm/bench 进程"
  dex "ss -ltn 2>/dev/null | grep -E ':(8848|8000|8080)' || echo '端口空闲'"

  echo "== 2. 解压并校验 =="
  if [ ! -d "$D" ]; then
    rm -rf "$W"; mkdir -p "$W"; unzip -q "$Z" -d "$W"
  fi
  ( cd "$D" && sha256sum -c SHA256SUMS 2>&1 | tail -6 )

  echo "== 3. 安装器参数 =="
  dex "cd $D && $PY scripts/install.py --help 2>&1 | head -40" > /tmp/r14_help.txt
  cat /tmp/r14_help.txt

  echo "== 4. 当前安装状态 =="
  for VV in /opt/corex311 /opt/corex311-cpython-vllm; do
    SSP=$VV/lib/python3.11/site-packages
    echo "---- $VV"
    dex "ls -ld $SSP/.host-opt-pr-backup 2>&1"
    dex "ls -l $SSP/vllm/v1/worker/host_opt.py $SSP/vllm/v1/worker/compact_greedy_backport.py 2>&1"
    dex "grep -c VLLM_HOST_OPT_POSITIONS $SSP/vllm/envs.py 2>/dev/null || echo 0"
  done

  echo "== 5. 如已有旧安装，先卸载恢复原厂源码 =="
  if timeout 30 docker exec "$C" bash -c "test -d $SP/.host-opt-pr-backup"; then
    echo "发现 $SP/.host-opt-pr-backup"
    if grep -qE -- '--uninstall|--revert|--restore' /tmp/r14_help.txt; then
      echo "使用安装器卸载"
      for flag in --uninstall --revert --restore; do
        if grep -q -- "$flag" /tmp/r14_help.txt; then
          dex "cd $D && $PY scripts/install.py --root $SP $flag 2>&1 | tail -20"; break
        fi
      done
    else
      echo "STOP: 已有旧安装，但安装器没有卸载参数；不覆盖，等人工确认"
      exit 5
    fi
  else
    echo "无旧安装备份，全新安装"
  fi

  echo "== 6. dry-run =="
  dex "cd $D && $PY scripts/install.py --root $SP --dry-run 2>&1 | tail -40"

  echo "== 7. 正式安装（编译原生模块，耗时可能几分钟）=="
  dexl "cd $D && $PY scripts/install.py --root $SP 2>&1 | tee $D/install-r14.log | tail -40"

  echo "== 8. check =="
  dex "cd $D && $PY scripts/install.py --root $SP --check 2>&1 | tail -30"

  echo "== 9. verify =="
  dexl "cd $D && $PY scripts/verify.py --root $SP 2>&1 | tail -40"

  echo "== 10. 安装后状态 =="
  dex "ls -ld $SP/.host-opt-pr-backup; ls $SP/.host-opt-pr-backup | head"
  dex "ls -l $SP/vllm/v1/worker/host_opt.py $SP/vllm/v1/worker/compact_greedy_backport.py 2>&1"
  echo -n "envs.py POSITIONS: "; dex "grep -c VLLM_HOST_OPT_POSITIONS $SP/vllm/envs.py"
  echo -n "compilation.py compact_greedy: "; dex "grep -c compact_greedy $SP/vllm/config/compilation.py"
  dex "$V/bin/pip list 2>/dev/null | grep -iE '^vllm|metadata'"
  echo "--- 开关默认值（应全关）---"
  dex "env | grep VLLM_HOST_OPT || echo '未设置 VLLM_HOST_OPT*（默认关闭）'"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
