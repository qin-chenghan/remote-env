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
  # 只读：确认停止状态下 docker cp 可用、两个 venv 的 vllm 补丁文件状态。
  # 只写入宿主 /tmp，不改容器内文件。

  CON=corex5-py311
  T=/tmp/184-venv-check
  mkdir -p "$T"

  echo "== 1. 容器状态与 overlay 路径 =="
  docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E "^$CON" || echo "container missing"
  docker inspect "$CON" --format 'Status={{.State.Status}} GraphDriver={{.GraphDriver.Name}} UpperDir={{.GraphDriver.Data.UpperDir}}' 2>&1

  echo "== 2. docker cp 试验（从停止的容器拷文件）=="
  docker cp "$CON:/opt/corex311/lib/python3.11/site-packages/vllm/v1/worker/gpu_model_runner.py" "$T/GMR_base.py" 2>&1 && echo "cp base runner OK"
  docker cp "$CON:/opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm/v1/worker/gpu_model_runner.py" "$T/GMR_new.py" 2>&1 && echo "cp new runner OK"
  echo "-- host_fastpath.py --"
  docker cp "$CON:/opt/corex311/lib/python3.11/site-packages/vllm/v1/worker/host_fastpath.py" "$T/HF_base.py" 2>&1 && echo "base HAS host_fastpath" || echo "base NO host_fastpath"
  docker cp "$CON:/opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm/v1/worker/host_fastpath.py" "$T/HF_new.py" 2>&1 && echo "new HAS host_fastpath" || echo "new NO host_fastpath"

  echo "== 3. 关键文件 hash（两边）=="
  for f in vllm/v1/worker/gpu_model_runner.py vllm/envs.py vllm/v1/attention/backends/ilu_flash_attn.py; do
    echo "-- $f"
    docker cp "$CON:/opt/corex311/lib/python3.11/site-packages/$f" "$T/base_$(basename $f)" 2>/dev/null && sha256sum "$T/base_$(basename $f)" | sed 's|'"$T"'/|  base |'
    docker cp "$CON:/opt/corex311-cpython-vllm/lib/python3.11/site-packages/$f" "$T/new_$(basename $f)" 2>/dev/null && sha256sum "$T/new_$(basename $f)" | sed 's|'"$T"'/|  new  |'
  done
  echo "-- 原生 .so --"
  for n in _host_opt_native.abi3.so _host_opt_meta_native.cpython-311-aarch64-linux-gnu.so; do
    for V in base new; do
      P=/opt/corex311/lib/python3.11/site-packages/vllm/$n
      [ "$V" = new ] && P=/opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm/$n
      docker cp "$CON:$P" "$T/$V-$n" 2>/dev/null && sha256sum "$T/$V-$n" | sed "s|$T/|  $V |" || echo "  $V $n MISSING"
    done
  done

  echo "== 4. 宿主机 /tmp 结果 =="
  ls -l "$T" | head -20

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
