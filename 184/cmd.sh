#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 对比 vllmBench_lite_opt.sh 与 vllmBench_lite_timeline.sh：启动服务/启动 bench 是否同一套。
# 纯 CPU：只读脚本与历史 run 配置，不启动 vllm、不动 GPU。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

BASE=/home/qch/scripts/litehost_perf/vllmBench
{
    echo "### server: $SERVER"
    echo "### host:   $(hostname)"
    echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    set -x

    # ---- 命令开始 ----
    echo "== 0. 找到两份脚本 =="
    find /home/qch /home/huawei_ts_program /home/lw -maxdepth 4 \
        -name 'vllmBench_lite_opt.sh' -o -name 'vllmBench_lite_timeline.sh' 2>/dev/null
    echo "-- 基本属性 --"
    for f in $(find /home/qch /home/huawei_ts_program /home/lw -maxdepth 4 \
            \( -name 'vllmBench_lite_opt.sh' -o -name 'vllmBench_lite_timeline.sh' \) 2>/dev/null | sort); do
        ls -l --time-style=long-iso "$f"
        sha256sum "$f"
        wc -l "$f"
    done

    echo "== 1. 两份脚本 diff =="
    OPT=$(find /home/qch /home/huawei_ts_program /home/lw -maxdepth 4 -name 'vllmBench_lite_opt.sh' 2>/dev/null | head -1)
    TL=$(find /home/qch /home/huawei_ts_program /home/lw -maxdepth 4 -name 'vllmBench_lite_timeline.sh' 2>/dev/null | head -1)
    echo "OPT=$OPT"; echo "TL=$TL"
    if [[ -n "$OPT" && -n "$TL" ]]; then
        diff -u "$OPT" "$TL" | head -400
    fi

    echo "== 2. 服务启动参数与 bench 客户端 =="
    for f in "$OPT" "$TL"; do
        [[ -n "$f" ]] || continue
        echo "-- $f --"
        grep -nE 'SERVER_ARGS|HOST_MEASURE=|bench_driver|bench serve|num_prompts|num-warmups|max-concurrency|random_input_len|random_output_len|seed|profiler-config|LD_PRELOAD|VLLM_RPC_TIMEOUT' "$f" | head -60
    done

    echo "== 3. bench_driver.py 是什么 =="
    HK=/home/huawei_ts_program/litehost_perf_opt
    [[ -f "$HK/bench_driver.py" ]] || HK=$(dirname "$OPT" 2>/dev/null)
    ls -l --time-style=long-iso "$HK/bench_driver.py" 2>/dev/null
    sed -n '1,90p' "$HK/bench_driver.py" 2>/dev/null
    grep -nE 'bench serve|vllm.entrypoints|subprocess|main\(|sys.argv|profile' "$HK/bench_driver.py" 2>/dev/null | head -30

    echo "== 4. 四轮 run 的实际配置对照 =="
    for R in $(ls -dt "$BASE"/*/ 2>/dev/null | head -40); do
        [[ -f "$R/config.txt" ]] || continue
        case "$(basename "$R")" in
            *4k*|*64k*|*timeline*) ;;
            *) continue ;;
        esac
        echo "-- $(basename "$R") --"
        cat "$R/config.txt"
    done

    echo "== 5. bench 请求参数（从 summary/json 佐证） =="
    for R in $(ls -dt "$BASE"/*/ 2>/dev/null | head -40); do
        [[ -f "$R/config.txt" ]] || continue
        case "$(basename "$R")" in
            *4k*|*64k*|*timeline*) ;;
            *) continue ;;
        esac
        echo "-- $(basename "$R") --"
        head -3 "$R/summary.csv" 2>/dev/null
        for j in "$R"/bs8_in128_out128*.json; do
            [[ -f "$j" ]] || continue
            python3 - "$j" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
keys=("num_prompts","max_concurrency","num_warmups","random_input_len","random_output_len","seed","model_id","date")
print({k:d.get(k) for k in keys})
PY
        done
    done

    # ---- 命令结束 ----

    set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
