#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 4k1 / 4k2 / 64k1 / 64k2 四份 timeline 采集：来源核对 + TSHG（trace 口径）汇总。
# 纯 CPU：只读日志、解析 trace，不启动 vllm、不动 GPU。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

BASE=/home/qch/scripts/litehost_perf/vllmBench
EVAL="$DIR/trace_eval_run.py"

pick_trace() {
    local r="$1"
    local -a fs=()
    mapfile -t fs < <(ls -1 "$r"/timeline/rank0.*.pt.trace.json.gz 2>/dev/null | sort)
    ((${#fs[@]} == 0)) && return 1
    ((${#fs[@]} == 1)) && { echo "${fs[0]}"; return 0; }
    # 多个 case 各有一次 profiler 落盘：取 in128_out128 bench 日志之后最近的那份
    local cl="$r/logs/bench_bs8_in128_out128.log"
    if [[ -f "$cl" ]]; then
        local t0 best="" bestd=999999 t d
        t0=$(stat -c %Y "$cl")
        for f in "${fs[@]}"; do
            t=$(stat -c %Y "$f"); d=$((t - t0))
            if ((d >= -30 && d < bestd)); then bestd=$d; best=$f; fi
        done
        [[ -n "$best" ]] && { echo "$best"; return 0; }
    fi
    echo "${fs[0]}"
}

{
    echo "### server: $SERVER"
    echo "### host:   $(hostname)"
    echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    set -x

    # ---- 命令开始 ----
    echo "== 0. 当前内核 / 页大小 / 引导表 =="
    uname -r
    getconf PAGE_SIZE
    uptime -s
    echo "-- 最近引导（run 的 started 对照这里找内核版本）--"
    last -x reboot shutdown 2>/dev/null | head -20

    echo "== 1. timeline* run 清单 =="
    RUNS=()
    while IFS= read -r d; do
        RUNS+=("${d%/}")
    done < <(ls -dt "$BASE"/*/ 2>/dev/null)
    echo "共 ${#RUNS[@]} 个目录"

    for R in "${RUNS[@]}"; do
        [[ -f "$R/config.txt" ]] || continue
        grep -q 'profile=1' "$R/config.txt" || continue
        echo "-- $(basename "$R") --"
        cat "$R/config.txt"
        grep -oE "'enable_prefix_caching': [A-Za-z]+|'compact_greedy': [A-Za-z]+|'sample_logits_cudagraph_scope': '[a-z_]+'" \
            "$R/logs/server.log" 2>/dev/null | sort -u
        grep -oE "Profiler with mode '[a-z]+'|Torch profiling enabled" "$R/logs/server.log" 2>/dev/null | sort -u
        echo "errors=$(grep -cE 'Traceback|ERROR' "$R/logs/server.log" 2>/dev/null || echo NA) tcmalloc_blocks=$(grep -c 'Tcmalloc page size' "$R/logs/server.log" 2>/dev/null || echo NA)"
        echo "profiler_dir: $(grep -oE "torch_profiler_dir='[^']+'" "$R/logs/server.log" 2>/dev/null | head -1)"
        echo "-- trace 文件 --"
        find "$R/timeline" -maxdepth 1 -name 'rank*.gz' -printf '%TY-%Tm-%Td %TH:%TM %10s %f\n' 2>/dev/null | sort
        echo "-- summary.csv --"
        head -5 "$R/summary.csv" 2>/dev/null
        echo
    done

    echo "== 2. TSHG + 逐函数（trace 口径，rank0，warmup 16，decode 主线程） =="
    for R in "${RUNS[@]}"; do
        [[ -f "$R/config.txt" ]] || continue
        grep -q 'profile=1' "$R/config.txt" || continue
        F="$(pick_trace "$R")" || { echo "### $(basename "$R") no rank0 trace"; continue; }
        echo "### 分析 $(basename "$R") <- $(basename "$F")"
        if command -v python3 >/dev/null 2>&1; then
            DEEP=1 DEEP_TOPN=250 GAP=1 GAP_TOPN=250 TSHG_WARMUP=0,16 \
                python3 "$EVAL" "$(basename "$R")" "$F"
        else
            DEEP=1 DEEP_TOPN=250 GAP=1 GAP_TOPN=250 TSHG_WARMUP=0,16 \
                docker exec -e DEEP=1 -e DEEP_TOPN=250 -e GAP=1 -e GAP_TOPN=250 \
                -e TSHG_WARMUP=0,16 \
                corex5-py311 python3 "$EVAL" "$(basename "$R")" "$F"
        fi
        echo
    done

    # ---- 命令结束 ----

    set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
