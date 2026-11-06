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
  # 与 184 第四批同一套指纹：确认 32 上 corex311 的 fastpath 形态与文件摘要。
  # 严格只读：不安装、不删除、不重启服务。

  CON=corex5-py311
  BASE=/opt/corex311
  SP="$BASE/lib/python3.11/site-packages"

  echo "== 1. 容器与 /opt 概览 =="
  docker ps --format '{{.Names}}	{{.Status}}' | head -10
  docker exec "$CON" sh -c 'ls -la --time-style=long-iso /opt 2>/dev/null'
  docker exec "$CON" sh -c 'df -h /opt /home 2>/dev/null | tail -3'

  echo "== 2. /opt 下的 venv =="
  docker exec "$CON" sh -c '
find /opt -maxdepth 3 -name pyvenv.cfg -print 2>/dev/null | while IFS= read -r cfg; do
  V=$(dirname "$cfg")
  echo "---- $V"
  grep -E "^(home|version|executable|command)" "$cfg"
  readlink "$V/bin/python" 2>/dev/null
done
'

  echo "== 3. corex311 当前补丁形态（两种都查）=="
  docker exec "$CON" sh -c '
SP=/opt/corex311/lib/python3.11/site-packages
echo "-- vllm/v1/worker 下 host/corex 相关文件 --"
ls -la $SP/vllm/v1/worker 2>/dev/null | grep -iE "host_fastpath|corex" || echo none
echo "-- site-packages/corex_host_native --"
find $SP/corex_host_native -maxdepth 3 -type f 2>/dev/null | head -20 || echo none
echo "-- 隐藏补丁目录 --"
ls -d $SP/vllm/.corex* 2>/dev/null || echo none
find $SP/vllm/.corex_metadata_patch -maxdepth 5 -type f 2>/dev/null | head -20
echo "-- *.orig / *.rej / *.bak --"
find $SP/vllm -maxdepth 7 \( -name "*.orig" -o -name "*.rej" -o -name "*.bak" \) 2>/dev/null | head -20
echo "-- 最近 7 天改动过的 vllm 文件（排除 pycache）--"
find $SP/vllm -mtime -7 -type f ! -path "*__pycache__*" -printf "%TY-%Tm-%Td %TH:%TM %10s %p\n" 2>/dev/null | sort | head -120
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
echo "-- 已安装的 .pth --"
ls -la $SP/*.pth 2>/dev/null | head -20
cat $SP/torch_module_attr_fastpath.pth 2>/dev/null
'

  echo "== 4. 关键包版本（与 184 对齐用）=="
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" -c '
import importlib.metadata as m
for n in ("vllm","torch","triton","transformers","tokenizers","numpy",
          "compressed-tensors","torch-module-attr-fastpath","apache-tvm-ffi",
          "hotspot-opt","protobuf","pydantic","fastapi","starlette","huggingface-hub"):
    try:
        print(f"{n}=={m.version(n)}")
    except Exception as e:
        print(f"{n} MISSING")
' 2>&1 | grep -v '^INFO' | tail -20

  echo "== 5. 正在运行的 vLLM（进程环境 + 启动时间）=="
  docker exec "$CON" sh -c '
ps -eo pid,lstart,args | grep -E "vllm.entrypoints.openai.api_server" | grep -v grep | head -5
for p in $(pgrep -f "vllm.entrypoints.openai.api_server" 2>/dev/null); do
  echo "-- PID $p --"
  tr "\0" "\n" < /proc/$p/environ 2>/dev/null | grep -E "VLLM_HOST_FASTPATH|COREX_HOST|TORCH_MODULE_ATTR|PYTHONPATH|HOTSPOT" | sort
  echo -n "  python: "; readlink /proc/$p/exe
done
'

  echo "== 6. 交付包是否也在 32 上（路径与 184 对照）=="
  docker exec "$CON" sh -c '
for D in /home/z30059427/host-opt-20261031/host-opt \
         /home/qch/transfer/host-opt-pr-validation-20261103-r3 \
         /home/qch/transfer ; do
  echo "-- $D --"
  ls -la --time-style=long-iso "$D" 2>/dev/null | head -25 || echo missing
done
echo "-- 找到的 host-opt 目录 --"
for R in /home/z30059427 /home/qch /home/huawei_ts_program; do
  find $R -maxdepth 5 -type d -name "*host-opt*" 2>/dev/null | head -10
done
'

  echo "== 7. 若有交付目录，列出其 BASELINE/install 与文件摘要 =="
  docker exec "$CON" sh -c '
PKG=/home/z30059427/host-opt-20261031/host-opt
if [ -d "$PKG" ]; then
  find "$PKG" -maxdepth 3 -type f -printf "%10s %TY-%Tm-%Td %TH:%TM %p\n" 2>/dev/null | sort -k4 | head -80
  echo "---- BASELINE.json"
  sed -n "1,80p" "$PKG/BASELINE.json" 2>/dev/null
  echo "---- patches/series"
  cat "$PKG/patches/series" 2>/dev/null
  echo "---- 关键文件 sha256"
  find "$PKG" \( -name "corex_host_opt.py" -o -name "*.so" -o -name "*.patch" \) -type f 2>/dev/null \
    | sort | xargs -r sha256sum | head -40
else
  echo "missing $PKG"
fi
'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
