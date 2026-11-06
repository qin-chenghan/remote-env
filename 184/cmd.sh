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
  # 本轮严格只读：不安装、不创建/修改 venv、不动运行中的服务。
  # 仅在本机 /tmp 写两个 pip freeze 临时文件用于 diff。

  CON=corex5-py311
  BASE=/opt/corex311
  NEW=/opt/corex311-cpython-vllm

  echo "== 1. 两个 venv 的壳子与解释器 =="
  docker exec "$CON" sh -c "ls -ld $BASE $NEW 2>&1; echo ---; du -sh $BASE $NEW 2>&1"
  docker exec "$CON" sh -c "echo '[base pyvenv.cfg]'; cat $BASE/pyvenv.cfg 2>&1; echo; echo '[new pyvenv.cfg]'; cat $NEW/pyvenv.cfg 2>&1"
  for V in "$BASE" "$NEW"; do
    echo "-- $V --"
    docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -c '
import sys, sysconfig
print("version      ", sys.version.split()[0])
print("sys.prefix   ", sys.prefix)
print("sys.base_prefix", sys.base_prefix)
print("executable   ", sys.executable)
args = sysconfig.get_config_var("CONFIG_ARGS") or ""
print("pgo          ", "--prefix=/opt/cpython-vllm/v1" in args)
print("config_args  ", args[:160])
' 2>&1 | tail -8
  done

  echo "== 2. 包集合 diff（freeze --all，已剔除 pip 警告）=="
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$CON" "$BASE/bin/python" -m pip freeze --all 2>/dev/null | sort > /tmp/freeze-base.txt
  docker exec -e PYTHONPATH= -e PYTHONHOME= -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$CON" "$NEW/bin/python" -m pip freeze --all 2>/dev/null | sort > /tmp/freeze-new.txt
  echo "base 包数: $(wc -l < /tmp/freeze-base.txt)"
  echo "new  包数: $(wc -l < /tmp/freeze-new.txt)"
  echo "-- 明细 diff（< 只在 base，> 只在 new）--"
  diff -u /tmp/freeze-base.txt /tmp/freeze-new.txt | head -160

  echo "== 3. pip check（依赖一致性）=="
  echo "-- base --"
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" -m pip check 2>&1 | head -20
  echo "-- new --"
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$NEW/bin/python" -m pip check 2>&1 | head -20

  echo "== 4. 关键包版本（base / new 对照）=="
  for pkg in torch vllm triton transformers compressed-tensors numpy \
             vllm-corex-metadata torch-module-attr-fastpath corex-host-fastpath hotspot-opt; do
    echo "-- $pkg --"
    printf '  base: '
    docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" -m pip show "$pkg" 2>/dev/null \
      | awk -F': ' '/^(Name|Version|Location)/{printf "%s=%s ", $1, $2} END{print ""}'
    printf '  new : '
    docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$NEW/bin/python" -m pip show "$pkg" 2>/dev/null \
      | awk -F': ' '/^(Name|Version|Location)/{printf "%s=%s ", $1, $2} END{print ""}'
  done

  echo "== 5. site-packages 里的 .pth / direct_url（看注入方式与 wheel 来源）=="
  docker exec "$CON" sh -c '
for V in /opt/corex311 /opt/corex311-cpython-vllm; do
  echo "-- $V --"
  ls -l $V/lib/python3.11/site-packages/*.pth 2>/dev/null || echo "no .pth"
  for f in $V/lib/python3.11/site-packages/*.pth; do
    [ -f "$f" ] && echo "  [$f]" && sed -n "1,3p" "$f"
  done
  for d in $V/lib/python3.11/site-packages/vllm-*.dist-info $V/lib/python3.11/site-packages/torch-*.dist-info; do
    [ -f "$d/direct_url.json" ] && echo "  $d/direct_url.json:" && cat "$d/direct_url.json"
  done
done
'

  echo "== 6. host fastpath 交付形态（这是关键分歧点）=="
  docker exec "$CON" sh -c '
for V in /opt/corex311 /opt/corex311-cpython-vllm; do
  SP=$V/lib/python3.11/site-packages
  echo "-- $V --"
  if [ -d $SP/vllm/v1/worker/host_fastpath ]; then
    echo "  host_fastpath dir: yes"
    ls -l $SP/vllm/v1/worker/host_fastpath
  else
    echo "  host_fastpath dir: no"
  fi
  if [ -f $SP/vllm/v1/worker/corex_host_opt.py ]; then
    echo "  corex_host_opt.py: yes ($(wc -c < $SP/vllm/v1/worker/corex_host_opt.py) bytes)"
  else
    echo "  corex_host_opt.py: no"
  fi
  if [ -d $SP/corex_host_native ]; then
    echo "  corex_host_native: yes"
    find $SP/corex_host_native -maxdepth 2 -type f | head -10
  else
    echo "  corex_host_native: no"
  fi
  echo -n "  gpu_model_runner host_fastpath 命中行数: "
  grep -c "host_fastpath" $SP/vllm/v1/worker/gpu_model_runner.py 2>/dev/null || echo 0
  sha256sum $SP/vllm/v1/worker/gpu_model_runner.py 2>/dev/null
  sha256sum $SP/vllm/model_executor/models/ilu_flash_attn.py 2>/dev/null
done
'
  echo "-- 两类 venv 中关键文件是否一致 --"
  for f in vllm/v1/worker/gpu_model_runner.py vllm/model_executor/models/ilu_flash_attn.py; do
    A=$(docker exec "$CON" sha256sum "$BASE/lib/python3.11/site-packages/$f" 2>/dev/null | awk '{print $1}')
    B=$(docker exec "$CON" sha256sum "$NEW/lib/python3.11/site-packages/$f" 2>/dev/null | awk '{print $1}')
    echo "$f"; echo "  base=$A"; echo "  new =$B"
  done

  echo "== 7. 容器级干扰项：PYTHONPATH / sitecustomize =="
  docker exec "$CON" sh -c 'echo PYTHONPATH=${PYTHONPATH:-<empty>}; echo PYTHONHOME=${PYTHONHOME:-<empty>}'
  docker exec "$CON" sh -c '
ls -l /home/huawei_ts_program/litehost_perf_opt/sitecustomize.py 2>/dev/null || echo "no litehost sitecustomize"
grep -n "HOST_FASTPATH\|torch_module_attr\|corex" /home/huawei_ts_program/litehost_perf_opt/sitecustomize.py 2>/dev/null | head -12
for V in /opt/corex311 /opt/corex311-cpython-vllm; do
  echo -n "$V sitecustomize: "; ls -l $V/lib/python3.11/site-packages/sitecustomize.py 2>/dev/null || echo none
done
'

  echo "== 8. import smoke（干净 PYTHONPATH，不占卡）=="
  echo "-- new venv --"
  timeout 180 docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$NEW/bin/python" -c '
import sys, sysconfig
print("prefix/base", sys.prefix, sys.base_prefix)
import torch
print("torch", torch.__version__, torch.__file__)
import vllm
print("vllm", vllm.__version__, vllm.__file__)
import transformers, compressed_tensors
print("transformers", transformers.__version__)
print("compressed_tensors", compressed_tensors.__version__)
print("pgo", "--prefix=/opt/cpython-vllm/v1" in (sysconfig.get_config_var("CONFIG_ARGS") or ""))
' 2>&1 | grep -vE '^(INFO|WARNING|DeprecationWarning)' | tail -12
  echo "-- new venv: torch fastpath status --"
  timeout 120 docker exec -e PYTHONPATH= -e PYTHONHOME= -e TORCH_MODULE_ATTR_FASTPATH=slot_native \
    "$CON" "$NEW/bin/python" -c 'import torch, torch_module_attr_fastpath as m; print(m.status())' 2>&1 | tail -3
  echo "-- base venv 对照 --"
  timeout 120 docker exec -e PYTHONPATH= -e PYTHONHOME= -e TORCH_MODULE_ATTR_FASTPATH=slot_native \
    "$CON" "$BASE/bin/python" -c 'import torch, torch_module_attr_fastpath as m; print(torch.__version__); print(m.status())' 2>&1 | tail -3

  echo "== 9. 厂商 bundle / hashed 清单 / 校验器 =="
  docker exec "$CON" sh -c '
B=/home/huawei_ts_program/corex5_py311_setup_20261029/assets/corex5-py311-20261009
echo "bundle: $B"
ls -l $B 2>/dev/null | head -10
echo -n "requirements-all.hashed.txt 行数: "; wc -l < $B/requirements-all.hashed.txt 2>/dev/null || echo missing
sed -n "1,4p" $B/requirements-all.hashed.txt 2>/dev/null
echo -n "wheels 数量: "; ls $B/wheels 2>/dev/null | wc -l
echo -n "vendor 数量: "; ls $B/vendor 2>/dev/null | wc -l
ls -l /home/huawei_ts_program/corex5_py311_setup_20261029/verify_corex311.py 2>/dev/null || echo "verify_corex311.py not at bundle parent"
'

  echo "== 10. 当前运行进程 / rebase 状态 / 磁盘（只读）=="
  pgrep -af 'vllm.entrypoints|bench_driver|vllmBench' 2>/dev/null | head -10 || true
  for p in $(pgrep -f 'vllm.entrypoints.openai.api_server' 2>/dev/null); do
    echo "-- PID $p exe: $(readlink -f /proc/$p/exe 2>/dev/null) --"
    tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -E 'PYTHONPATH|VIRTUAL_ENV|VLLM_HOST_FASTPATH|TORCH_MODULE_ATTR' || true
  done
  docker exec "$CON" sh -c 'ls -lt /root/.local/state/cpython-vllm-rebase 2>/dev/null | head -6'
  docker exec "$CON" sh -c 'df -h /opt /home | tail -3'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
