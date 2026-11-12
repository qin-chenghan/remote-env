#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 203 容器内现状（只读，修正变量引用）：r14 / 旧 fastpath / tcmalloc / Python.h / PGO 复核。
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
  dex() { timeout 240 docker exec "$C" bash -c "$1"; }

  echo "== 1. r14 三补丁在容器内的落盘状态 =="
  dex 'V=/opt/corex311; SP=$V/lib/python3.11/site-packages; echo "SP=$SP"; ls -ld $SP/.host-opt-pr-backup 2>&1; ls $SP/vllm/v1/worker/host_opt.py $SP/vllm/v1/worker/compact_greedy_backport.py 2>&1'
  dex 'SP=/opt/corex311/lib/python3.11/site-packages; echo -n "envs VLLM_HOST_OPT*: "; grep -oE "VLLM_HOST_OPT[A-Z_]*" $SP/vllm/envs.py 2>/dev/null | sort -u | tr "\n" " "; echo; echo -n "compilation compact_greedy: "; grep -c compact_greedy $SP/vllm/config/compilation.py 2>/dev/null'

  echo "== 2. 旧版 host fastpath =="
  dex 'SP=/opt/corex311/lib/python3.11/site-packages; ls -l $SP/vllm/v1/worker/corex_host_opt.py 2>&1; ls -d $SP/vllm/v1/worker/host_fastpath 2>&1; echo -n "envs VLLM_HOST_FASTPATH: "; grep -c VLLM_HOST_FASTPATH $SP/vllm/envs.py 2>/dev/null; echo -n "worker 内引用: "; grep -rIl VLLM_HOST_FASTPATH $SP/vllm/v1/worker/ 2>/dev/null | head -5'
  dex 'SP=/opt/corex311/lib/python3.11/site-packages; grep -oE "COREX_HOST[A-Z_]*" $SP/vllm/envs.py 2>/dev/null | sort -u | head -10'

  echo "== 3. torch module attrs fastpath =="
  dex 'SP=/opt/corex311/lib/python3.11/site-packages; grep -rIl TORCH_MODULE_ATTR_FASTPATH $SP/vllm $SP/torch 2>/dev/null | head -6; ls -l $SP/torch/_C*.so 2>/dev/null | head -3'

  echo "== 4. tcmalloc =="
  dex 'V=/opt/corex311; find /usr/lib /usr/lib64 /usr/local/lib /usr/local/lib64 $V/lib $V/lib64 -maxdepth 3 -name "libtcmalloc*.so*" 2>/dev/null | head -10; echo "--- venv 内 ---"; find $V -maxdepth 4 -name "libtcmalloc*.so*" 2>/dev/null | head -5'
  echo "--- 宿主 /home 全盘（限深度）---"
  find /home -maxdepth 5 -name 'libtcmalloc*.so*' 2>/dev/null | head -5 || true
  find /home -maxdepth 4 -type d -name 'gperftools*' 2>/dev/null | head -5 || true

  echo "== 5. Python.h 与构建依赖 =="
  dex 'ls -l /opt/python-3.11.6/include/python3.11/Python.h 2>&1; ls -l /opt/corex311/include/python3.11/Python.h 2>&1; python3 -c "print(1)" 2>/dev/null'
  dex 'ls /usr/include/torch 2>/dev/null | head -3; ls /opt/corex311/lib/python3.11/site-packages/torch/include/torch 2>/dev/null | head -3'

  echo "== 6. r14 包在 203 上的状态 =="
  Z=/home/z30059427/host-opt-three-pr-validation-r14-arm64-py311-20261112.zip
  D=/home/z30059427/host-opt-pr-validation-20261106-r14
  ls -l "$Z" "$D" 2>&1 | head -5
  ls "$D" 2>/dev/null | head -10
  ls "$D/scripts" "$D/container/patches" 2>/dev/null | head -10
  echo "--- 证据文件 ---"
  head -30 "$D/evidence/r14-performance-20261112.md" 2>/dev/null

  echo "== 7. PGO 复核 =="
  dex 'ls -d /opt/cpython-vllm 2>&1; ls /opt/cpython-vllm/v1/bin 2>&1 | head -5; command -v cpython-vllm-rebase || echo "无 rebase 工具"; /opt/corex311/bin/python -c "import sys,sysconfig;print(sys.base_prefix);print(sysconfig.get_config_var(\"CONFIG_ARGS\"))"'

  echo "== 8. 容器内空间与现有服务 =="
  dex 'df -h /opt /home | tail -3; du -sh /opt/corex311 2>/dev/null'
  dex 'ps -eo pid,etime,args | grep -E "vllm|bench_driver" | grep -v grep | head -5 || echo "无 vllm 进程"'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
