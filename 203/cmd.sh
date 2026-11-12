#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 203 PGO 前置条件盘点（只读）：/opt/cpython-vllm、建 PGO 解释器和 venv 的脚本/物料、tcmalloc。
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

  echo "== 1. PGO 解释器与 venv 物料 =="
  dex 'ls -d /opt/cpython-vllm* 2>&1; ls /opt/cpython-vllm/v1/bin 2>&1 | head -5'
  dex 'ls -d /opt/corex311* 2>&1; du -sh /opt/corex311 2>/dev/null; ls /opt/corex311-manifest 2>/dev/null | head -10'
  dex 'command -v cpython-vllm-rebase 2>/dev/null || echo "无 rebase 工具"; ls /opt/corex311/bin | grep -iE "rebase|corex|pip" | head -10'

  echo "== 2. 建解释器的脚本 build_corex.py =="
  dex 'ls -l /home/qch/scripts/litehost_perf/build_corex.py /home/qch/transfer/litehost_perf/build_corex.py 2>&1'
  echo "--- 头部注释/用法 ---"
  head -40 /home/qch/scripts/litehost_perf/build_corex.py 2>/dev/null
  echo "--- grep 关键参数 ---"
  grep -nE "with-lto|enable-optimizations|PGO|profile|prefix|configure|make -j|BUILD" /home/qch/scripts/litehost_perf/build_corex.py 2>/dev/null | head -20

  echo "== 3. 建 venv 的脚本与 bundle =="
  dex 'ls -l /home/z30059427/corex5-py311-* 2>/dev/null | head -10'
  find /home -maxdepth 3 -name 'install_corex311.sh' 2>/dev/null | head -5
  dex 'ls /home/qch/transfer/*.whl /home/qch/transfer/*.tar.gz 2>/dev/null | head -10'

  echo "== 4. CPython 源码与 gperftools 物料 =="
  find /home /opt -maxdepth 4 \( -iname 'Python-3.11*' -o -iname 'cpython-3.11*' -o -iname 'Python-3*.tar.*' \) 2>/dev/null | head -10
  find /home -maxdepth 4 \( -iname 'gperftools*' -o -iname 'libtcmalloc*' \) 2>/dev/null | head -10
  dex 'find /opt /usr/local /usr/lib -maxdepth 3 -iname "libtcmalloc*" 2>/dev/null | head -5'

  echo "== 5. 网络与 pip（建 venv 要联网）=="
  dex 'cat /root/.pip/pip.conf 2>/dev/null | head -10; env | grep -iE "proxy|CONSTRAINT" || echo "容器无 proxy 变量"'
  echo "--- 代理可达性 ---"
  timeout 20 curl -sS -o /dev/null -w 'proxy_http=%{http_code}\n' -x http://141.1.61.31:3129 http://mirrors.aliyun.com/ 2>&1 || echo "代理不可达"
  timeout 20 docker exec -e http_proxy=http://141.1.61.31:3129 -e https_proxy=http://141.1.61.31:3129 "$C" bash -c 'curl -sS -o /dev/null -w "container_mirror=%{http_code}\n" https://mirrors.aliyun.com/ 2>&1 | tail -2' || echo "容器内代理不可达"

  echo "== 6. 构建能力与空间 =="
  nproc
  dex 'nproc; df -h /opt /home | tail -3'
  dex 'ls /usr/include/zlib.h /usr/include/ssl/opensslconf.h /usr/include/ffi.h /usr/include/ncurses.h 2>&1 | head -6; dpkg -l | grep -cE "^ii  (build-essential|libssl-dev|zlib1g-dev|libffi-dev|libncurses.*dev|libbz2-dev|liblzma-dev|libsqlite3-dev)"'

  echo "== 7. r14 与旧 fastpath 复核（沿用上一轮）=="
  dex 'SP=/opt/corex311/lib/python3.11/site-packages; echo -n "r14 backup: "; ls -d $SP/.host-opt-pr-backup 2>/dev/null || echo 无; echo -n "host_opt.py: "; ls -l $SP/vllm/v1/worker/host_opt.py 2>/dev/null || echo 无; echo -n "envs opts: "; grep -oE "VLLM_HOST_OPT[A-Z_]*" $SP/vllm/envs.py 2>/dev/null | sort -u | tr "\n" " "; echo; echo -n "fastpath file: "; ls -l $SP/vllm/v1/worker/corex_host_opt.py 2>/dev/null || echo 无; echo -n "envs fastpath: "; grep -c VLLM_HOST_FASTPATH $SP/vllm/envs.py 2>/dev/null'

  echo "== 8. 203 上已有的 r14 包与证据 =="
  ls -l /home/z30059427/host-opt-three-pr-validation-r14-arm64-py311-20261112.zip 2>&1
  head -20 /home/z30059427/host-opt-pr-validation-20261106-r14/evidence/r14-performance-20261112.md 2>/dev/null

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
