#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 本次：只读。确认 184 base venv 里的 VLLM_DISABLE_DECODE_FASTPATH 是否仍然存在。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

{
    echo "### server: $SERVER"
    echo "### host:   $(hostname)"
    echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "### repo:   $ROOT"
    echo
    set -x

    # ---- 命令开始 ----
    echo "== 1. base venv: grep / hash / context =="
    docker exec corex5-py311 bash -lc '
        f=/opt/corex311/lib/python3.11/site-packages/vllm/v1/worker/gpu_model_runner.py
        ls -l "$f"
        echo "-- grep -c --"
        grep -c VLLM_DISABLE_DECODE_FASTPATH "$f" || true
        echo "-- sha256 --"
        sha256sum "$f"
        echo "-- context --"
        grep -n -B4 -A8 VLLM_DISABLE_DECODE_FASTPATH "$f" | head -40
    '

    echo "== 2. PGO venv: grep / hash =="
    docker exec corex5-py311 bash -lc '
        f=/opt/corex311-cpython-vllm/lib/python3.11/site-packages/vllm/v1/worker/gpu_model_runner.py
        if [ -f "$f" ]; then
            ls -l "$f"
            echo "-- grep -c --"
            grep -c VLLM_DISABLE_DECODE_FASTPATH "$f" || true
            echo "-- sha256 --"
            sha256sum "$f"
        else
            echo "missing: $f"
        fi
    '

    echo "== 3. 对照 hash =="
    echo "with-fastpath  : b869bfb1e34bb48b6fe9333a734bb96d97585bd2017bef5ab21a4e36b5370fbe"
    echo "stock-no-patch : ff9f2df42976347b85fbd6e12623b217e1beda6d5248a5662b3cf397eacaef59"
    # ---- 命令结束 ----

    set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
