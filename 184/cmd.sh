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
  # 第四批：定位“今天用 zip 装进 corex311 的 fastpath”到底是哪一套、改了哪些文件。
  # 严格只读：不安装、不删除、不重启服务。

  CON=corex5-py311
  BASE=/opt/corex311
  SP="$BASE/lib/python3.11/site-packages"
  PKG=/home/qch/transfer/host-opt-pr-validation-20261103-r3
  ZIP=/home/qch/transfer/host-opt-two-pr-validation-20261103-r3-arm64-py311-py312.zip

  echo "== 1. transfer 下的交付包与 zip =="
  ls -la --time-style=long-iso "$PKG" 2>/dev/null || echo "missing $PKG"
  echo "-- zip --"
  ls -l --time-style=long-iso "$ZIP" 2>/dev/null || echo "missing $ZIP"
  sha256sum "$ZIP" 2>/dev/null
  echo "-- zip 清单 --"
  unzip -l "$ZIP" 2>/dev/null | head -80 || echo "unzip failed"
  echo "-- transfer/SHA256SUMS --"
  cat /home/qch/transfer/SHA256SUMS 2>/dev/null

  echo "== 2. 交付目录文件树（按路径排序）=="
  find "$PKG" -maxdepth 5 -type f -printf '%10s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort -k4 | head -120
  echo "-- 交付包自校验 --"
  ( cd "$PKG" && sha256sum -c SHA256SUMS 2>&1 | tail -10 ) || echo "SHA256SUMS check failed or missing"

  echo "== 3. README / BASELINE / install.sh / patches/series =="
  for f in "$PKG"/README* "$PKG"/BASELINE.json "$PKG"/scripts/install.sh "$PKG"/patches/series; do
    [ -f "$f" ] || continue
    echo "---- $f"
    sed -n '1,100p' "$f"
  done

  echo "== 4. patch 触及的目标文件 =="
  for p in "$PKG"/patches/*.patch; do
    [ -f "$p" ] || continue
    echo "-- $(basename "$p")"
    grep -E '^(diff --git|--- |\+\+\+ )' "$p" | head -20
  done

  echo "== 5. 交付包内关键文件 sha256 =="
  find "$PKG" \( -name 'host_fastpath.py' -o -name 'corex_host_opt.py' -o -name '*.so' \
       -o -name 'MANIFEST.json' -o -name 'SHA256SUMS' -o -name 'README.md' \
       -o -name '*.patch' -o -name 'install.py' -o -name 'verify.py' \) -type f 2>/dev/null \
    | sort | xargs -r sha256sum | head -80

  echo "== 6. corex311 当前补丁形态（两种都查）=="
  docker exec "$CON" sh -c '
SP=/opt/corex311/lib/python3.11/site-packages
echo "-- vllm/v1/worker 下 host/corex 相关文件 --"
ls -la $SP/vllm/v1/worker 2>/dev/null | grep -iE "host_fastpath|corex" || echo none
echo "-- site-packages/corex_host_native --"
find $SP/corex_host_native -maxdepth 3 -type f 2>/dev/null | head -20 || echo none
echo "-- 隐藏补丁目录 --"
ls -d $SP/vllm/.corex* 2>/dev/null || echo none
find $SP/vllm/.corex_metadata_patch -maxdepth 5 -type f 2>/dev/null | head -20
echo "-- .corex_metadata_patch/originals 与当前文件对比 --"
ORIG=$SP/vllm/.corex_metadata_patch/originals
if [ -d "$ORIG" ]; then
  find "$ORIG" -type f | while IFS= read -r o; do
    rel=${o#$ORIG/}
    cur=$SP/vllm/$rel
    if [ -f "$cur" ]; then
      a=$(sha256sum "$o" | cut -d" " -f1)
      b=$(sha256sum "$cur" | cut -d" " -f1)
      [ "$a" = "$b" ] && echo "SAME $rel" || echo "DIFF $rel"
    else
      echo "GONE $rel"
    fi
  done
else
  echo "no originals dir"
fi
echo "-- install.py 备份/状态目录 --"
find $SP -maxdepth 2 -iname "*host*opt*" 2>/dev/null | head -20
echo "-- vllm 根目录 _host_opt_native --"
ls -la $SP/vllm/_host_opt_native* 2>/dev/null || echo none
for f in $SP/vllm/_host_opt_native*.so; do [ -f "$f" ] && sha256sum "$f"; done
echo "-- *.orig / *.rej / *.bak --"
find $SP/vllm -maxdepth 7 \( -name "*.orig" -o -name "*.rej" -o -name "*.bak" \) 2>/dev/null | head -20
echo "-- 今天 10:00 后被改动的 vllm 文件（排除 pycache）--"
find $SP/vllm -newermt "2026-11-06 10:00" -type f ! -path "*__pycache__*" -printf "%TY-%Tm-%Td %TH:%TM %10s %p\n" 2>/dev/null | sort | head -100
echo "-- 关键文件 sha256 --"
for f in vllm/v1/worker/gpu_model_runner.py \
         vllm/v1/worker/host_fastpath.py \
         vllm/v1/worker/corex_host_opt.py \
         vllm/v1/attention/backends/ilu_flash_attn.py \
         vllm/model_executor/models/ilu_flash_attn.py ; do
  [ -f "$SP/$f" ] && sha256sum "$SP/$f" || echo "MISSING $f"
done
echo "-- 原生扩展 .so 及其 sha256 --"
find $SP/corex_host_native -name "*.so" -type f -exec sha256sum {} \; 2>/dev/null | head -20
'

  echo "== 7. 交付包若带 vllm 源码树，与已安装树直接 diff =="
  docker exec "$CON" sh -c '
PKG=/home/qch/transfer/host-opt-pr-validation-20261103-r3
SP=/opt/corex311/lib/python3.11/site-packages
if [ -d "$PKG/vllm" ]; then
  echo "-- diff -rq $PKG/vllm vs $SP/vllm --"
  diff -rq "$PKG/vllm" "$SP/vllm" 2>/dev/null | grep -v __pycache__ | head -60
else
  echo "no $PKG/vllm tree"
fi
'

  echo "== 8. 正在运行的 vLLM 用的是哪套（进程环境 + 启动时间）=="
  docker exec "$CON" sh -c '
ps -eo pid,lstart,args | grep -E "vllm.entrypoints.openai.api_server" | grep -v grep | head -5
for p in $(pgrep -f "vllm.entrypoints.openai.api_server" 2>/dev/null); do
  echo "-- PID $p --"
  tr "\0" "\n" < /proc/$p/environ 2>/dev/null | grep -E "VLLM_HOST_FASTPATH|COREX_HOST|TORCH_MODULE_ATTR|PYTHONPATH|HOTSPOT" | sort
  echo -n "  python: "; readlink /proc/$p/exe
done
'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
