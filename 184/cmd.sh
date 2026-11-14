#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 安装"全优化开关"版 timeline_opt.sh:备份原文件 -> 覆盖 -> 语法检查 -> diff -> 校验编译配置键。
# 纯 CPU,不启动 vllm,不动 GPU。
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
  SRC="$DIR/timeline_opt.sh"
  DST=/home/qch/scripts/timeline_opt.sh
  BAK="$DST.bak-$TS"
  SUDO=""

  echo "== 0. 源文件 =="
  ls -l --time-style=long-iso "$SRC" || exit 1
  sha256sum "$SRC" 2>/dev/null || shasum -a 256 "$SRC"

  echo "== 1. 目标可写性 =="
  ls -l --time-style=long-iso "$DST"
  if [ -w "$(dirname "$DST")" ] && { [ ! -e "$DST" ] || [ -w "$DST" ]; }; then
    echo "可直接写"
  elif sudo -n true 2>/dev/null; then
    SUDO="sudo"; echo "需要 sudo(已免密)"
  else
    echo "目标不可写且 sudo 需要密码"
  fi

  echo "== 2. 备份 =="
  if $SUDO cp -p "$DST" "$BAK"; then
    ls -l --time-style=long-iso "$BAK"
  else
    echo "备份失败,放弃安装"; exit 2
  fi

  echo "== 3. 覆盖 =="
  if $SUDO cp "$SRC" "$DST" && $SUDO chmod +x "$DST"; then
    ls -l --time-style=long-iso "$DST"
    sha256sum "$DST" 2>/dev/null || shasum -a 256 "$DST"
  else
    echo "覆盖失败,原文件仍在备份 $BAK"; exit 3
  fi

  echo "== 4. 语法检查 =="
  bash -n "$DST" && echo "bash -n OK"

  echo "== 5. 与原文件的差异 =="
  diff -u "$BAK" "$DST" | sed -n '1,200p'

  echo "== 6. venv 里的 CompilationConfig 是否认识新键 =="
  for k in compact_greedy sample_logits_cudagraph_scope; do
    if timeout 60 docker exec corex5-py311 bash -c \
        "grep -nE '^[[:space:]]*$k:' /opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm/config/compilation.py"; then
      :
    else
      echo "!! 缺少 $k"
    fi
  done

  echo "== 7. 关键开关行(落盘后的脚本) =="
  grep -nE 'COMPILATION_CONFIG=|VLLM_HOST_OPT|UMD_MAX|TORCH_MODULE|LD_PRELOAD|compact_greedy' "$DST"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
