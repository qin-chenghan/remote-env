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
  # 把 corex311 的 host fastpath 补丁文件迁入 corex311-cpython-vllm。
  # 容器已停止：直接操作 overlay UpperDir；先备份目标文件，后校验 hash，最后复验整树 diff。

  CON=corex5-py311
  U=$(docker inspect "$CON" --format '{{.GraphDriver.Data.UpperDir}}')
  SRC="$U/opt/corex311/lib/python3.11/site-packages/vllm"
  DST="$U/opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm"
  BAK=/tmp/184-new-venv-backup
  mkdir -p "$BAK"

  PYFILES="envs.py v1/attention/backends/ilu_flash_attn.py v1/worker/gpu_model_runner.py"
  SOFILES="_host_opt_native.abi3.so _host_opt_meta_native.cpython-311-aarch64-linux-gnu.so"
  HFILE="v1/worker/host_fastpath.py"

  echo "== 0. 前置检查（容器必须停止）=="
  [ "$(docker inspect "$CON" --format '{{.State.Status}}')" = "exited" ] || { echo "ABORT: 容器不是 stopped 状态"; exit 1; }
  echo "container stopped"

  echo "== 1. 迁移前 hash（目标侧）=="
  for f in $PYFILES; do
    [ -f "$DST/$f" ] && sha256sum "$DST/$f" | sed "s|$DST/|  new |" || echo "  new $f MISSING"
  done
  for f in $SOFILES $HFILE; do
    [ -f "$DST/$f" ] && echo "  new $f EXISTS(将备份)" || echo "  new $f MISSING(预期)"
  done

  echo "== 2. 备份目标侧已有文件 =="
  for f in $PYFILES $SOFILES $HFILE; do
    [ -f "$DST/$f" ] && { mkdir -p "$BAK/$(dirname "$f")"; cp -p "$DST/$f" "$BAK/$f"; echo "backup $f"; }
  done
  ls -R "$BAK" | head -20

  echo "== 3. 复制补丁文件 =="
  for f in $PYFILES $SOFILES $HFILE; do
    if [ ! -f "$SRC/$f" ]; then echo "FAIL: source missing $f"; exit 1; fi
    mkdir -p "$DST/$(dirname "$f")"
    cp -p "$SRC/$f" "$DST/$f"
    echo "copied $f"
  done

  echo "== 4. 迁移后 hash 对比（src vs dst）=="
  for f in $PYFILES $SOFILES $HFILE; do
    a=$(sha256sum "$SRC/$f" | cut -d' ' -f1)
    b=$(sha256sum "$DST/$f" | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then echo "OK  $f  $a"; else echo "MISMATCH $f  $a vs $b"; fi
  done

  echo "== 5. 删除目标侧陈旧的 __pycache__ 字节码 =="
  for f in $PYFILES; do
    base=$(basename "$f" .py)
    rm -f "$DST/$(dirname "$f")/__pycache__/$base".cpython-311*.pyc 2>/dev/null && echo "removed stale pyc for $f" || true
  done

  echo "== 6. 复验 vllm 树 diff（预期只剩 .swp）=="
  diff -rq --exclude='__pycache__' "$SRC" "$DST" 2>&1 | head -20
  echo "-- 统计 --"
  diff -rq --exclude='__pycache__' "$SRC" "$DST" 2>/dev/null | wc -l

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
