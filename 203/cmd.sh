#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 203 corex5-py311 容器内现状盘点（只读）：PGO、tcmalloc、r14、旧 fastpath、构建环境。
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
  V=/opt/corex311
  SP=$V/lib/python3.11/site-packages
  PY=$V/bin/python
  dex() { timeout 150 docker exec "$C" bash -c "$1"; }

  echo "== 1. 容器与 venv 基本状态 =="
  dex "cat /etc/os-release 2>/dev/null | head -2; uname -m; ls -d /opt/corex311* 2>/dev/null"
  dex "env | grep -E 'PYTHONPATH|PYTHONHOME|LD_PRELOAD|VLLM_|COREX_|HOTSPOT' || echo '无相关环境变量'"
  dex "$PY -c 'import sys,sysconfig;print(sys.version);print(sys.executable);print(sys.base_prefix);print(sysconfig.get_config_var(\"CONFIG_ARGS\"))'"
  dex "$PY -c 'import vllm, torch;print(\"vllm\",vllm.__version__);print(\"torch\",torch.__version__, torch.__file__)'"

  echo "== 2. PGO =="
  dex "ls -d /opt/cpython-vllm* 2>/dev/null; ls /opt/cpython-vllm/v1/bin 2>/dev/null | head -5"
  dex "command -v cpython-vllm-rebase; ls -l \$V/bin/cpython-vllm-rebase 2>/dev/null"
  dex "find \$V -maxdepth 2 -name 'plan.json' -o -maxdepth 2 -name '*.rebase*' 2>/dev/null | head -10"

  echo "== 3. tcmalloc =="
  dex "find /usr/lib64 /usr/local/lib /usr/local/lib64 \$V/lib \$SP -maxdepth 3 -name 'libtcmalloc*.so*' 2>/dev/null | head -10"
  echo "--- 宿主 /home 下的 gperftools ---"
  ls -l /home/*/gperftools/.libs/libtcmalloc.so 2>/dev/null | head -5 || echo "无"
  find /home -maxdepth 4 -name 'libtcmalloc*.so*' 2>/dev/null | head -5

  echo "== 4. r14 三补丁 =="
  dex "ls -ld \$SP/.host-opt-pr-backup 2>&1"
  dex "ls -l \$SP/vllm/v1/worker/host_opt.py \$SP/vllm/v1/worker/compact_greedy_backport.py 2>&1"
  dex "grep -oE 'VLLM_HOST_OPT[A-Z_]*' \$SP/vllm/envs.py 2>/dev/null | sort -u"
  dex "grep -c compact_greedy \$SP/vllm/config/compilation.py 2>/dev/null"

  echo "== 5. 旧版 host fastpath（VLLM_HOST_FASTPATH 四项）=="
  dex "ls -l \$SP/vllm/v1/worker/corex_host_opt.py \$SP/vllm/v1/worker/host_fastpath 2>&1 | head -8"
  dex "grep -rIl 'VLLM_HOST_FASTPATH' \$SP/vllm/envs.py \$SP/vllm/v1/worker/*.py 2>/dev/null | head -5"
  dex "grep -oE 'COREX_HOST_[A-Z_]*' \$SP/vllm/envs.py 2>/dev/null | sort -u | head -10"

  echo "== 6. torch module attrs fastpath =="
  dex "grep -rIl 'TORCH_MODULE_ATTR_FASTPATH' \$SP 2>/dev/null | head -5"
  dex "ls -l \$SP/*fastpath* \$SP/torch/_module_fastpath* 2>/dev/null | head -5"

  echo "== 7. 构建环境（r14 原生模块要 cmake+gcc）=="
  dex "which gcc g++ cc cmake ninja make 2>&1 | head -8; gcc --version 2>/dev/null | head -1; cmake --version 2>/dev/null | head -1"
  dex "ls \$V/include/python3.11/Python.h 2>/dev/null || echo 'venv 无 Python.h'"
  dex "df -h / /opt /home 2>/dev/null | tail -4"

  echo "== 8. 多流参数与 GPU =="
  cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null
  timeout 30 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'MiB /' | head -5

  echo "== 9. 迁移包是否已在 203 =="
  ls -l /home/qch/transfer/ 2>/dev/null | head -15
  find /home -maxdepth 4 -iname '*host-opt*' -o -maxdepth 4 -iname '*r14*' 2>/dev/null | head -10

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
