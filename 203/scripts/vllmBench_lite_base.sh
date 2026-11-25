#!/usr/bin/env bash
# Adapted from the uploaded vllmBench_lite.sh. Keep one server for all cases.
# Defaults retained: warmups=16, cache OFF, CPUs 192-255 (NUMA node 3), backend=vllm.
# Requires the matching files in this slim folder (included in the ZIP).

#
# ---- 基线版（以 vllmBench_lite_opt.sh 的 r14 骨架倒推）----
#   流程与 opt 脚本一致，仅默认关闭全部优化：
#     PREFIX=/opt/corex311          基线 venv（无 PGO、无 r14 补丁）
#     HOST_PATH=off                 VLLM_HOST_OPT* 全 off
#     MIMALLOC=off                  不注入 mimalloc
#     COMPILATION_CONFIG_EXTRA={}   不带 compact / 采样小图
#     TORCH_MODULE_ATTR_FASTPATH    不设置（并从调用方环境剥离）
#   各开关仍可用环境变量覆盖，便于在基线 venv 上做单项对照。
set -uo pipefail

MODEL_PATH="${MODEL_PATH:-/home/hc/modules/Qwen3-32B-W8A8}"
TEST_ID="${TEST_ID:-"vllmBase_$(date +%Y%m%d_%H%M%S)"}"
PREFIX="${PREFIX:-/opt/corex311}"
PYTHON_BIN="${PYTHON_BIN:-${PREFIX}/bin/python3}"
GPU_LIST="${GPU_LIST:-0,1,2,3}"
GPUS_PER_INSTANCE="${GPUS_PER_INSTANCE:-4}"
PORT="${PORT:-8848}"
NUM_PROMPTS="${NUM_PROMPTS:-100}"
NUM_WARMUPS="${NUM_WARMUPS:-16}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-8}"
CASE_INTERVAL="${CASE_INTERVAL:-60}"
CPU_RANGE="${CPU_RANGE-0-15,128-143}"
HOST_MEASURE="${HOST_MEASURE:-lite}"         # lite | off (never enable Torch Profiler here)
HOST_LINK_PERCENT="${HOST_LINK_PERCENT:-0}" # 5 means 5%, computed offline
HOST_TIMEOUT="${HOST_TIMEOUT:-120}"
HOST_MAX_SCOPES="${HOST_MAX_SCOPES:-200000}"
HOST_DRY_RUN="${HOST_DRY_RUN:-0}"

# ------------------------------------------------------------------
# 优化开关组（全部可用环境变量覆盖）。基线默认全关；若把 PREFIX 指向 r14
# venv，可用 HOST_PATH=on 做同环境对照。
#   HOST_PATH=on|off  整组 Host 路径优化。off 时所有子项显式 off（补丁仍在源码里，
#                     但走原厂设备计算路径）。
#   MIMALLOC=on|off   是否注入 mimalloc 3.6.1（LD_PRELOAD）。
# ------------------------------------------------------------------
HOST_PATH="${HOST_PATH:-off}"
MIMALLOC="${MIMALLOC:-off}"

# Host 路径子项：单项优先于总开关。
# POSITIONS 在 r13+ 未显式设置时继承总开关；本脚本一律显式下发，避免配置漂移。
if [[ "$HOST_PATH" == on ]]; then
    HOST_OPT_TOTAL="${VLLM_HOST_OPT:-on}"
    HOST_OPT_INPUTS="${VLLM_HOST_OPT_INPUTS:-on}"
    HOST_OPT_ARENA="${VLLM_HOST_OPT_ARENA:-on}"
    HOST_OPT_BOOKKEEPING="${VLLM_HOST_OPT_BOOKKEEPING:-on}"
    HOST_OPT_POSITIONS="${VLLM_HOST_OPT_POSITIONS:-$HOST_OPT_TOTAL}"
    HOST_OPT_METADATA="${VLLM_HOST_OPT_METADATA:-on}"
    HOST_OPT_DIAGNOSTICS="${VLLM_HOST_OPT_DIAGNOSTICS:-0}"
else
    HOST_OPT_TOTAL=off
    HOST_OPT_INPUTS=off
    HOST_OPT_ARENA=off
    HOST_OPT_BOOKKEEPING=off
    HOST_OPT_POSITIONS=off
    HOST_OPT_METADATA=off
    HOST_OPT_DIAGNOSTICS=0
fi

# positions 依赖 arena：arena 未生效时 positions 会自动退回设备计算并打 warning。
if [[ "$HOST_OPT_POSITIONS" == on && "$HOST_OPT_ARENA" != on ]]; then
    echo 'WARNING: VLLM_HOST_OPT_POSITIONS=on 但 ARENA!=on，positions 将退回设备计算' >&2
fi
SERVER_EXTRA_ENV=(
    UMD_MAXCOMMANDBUFFERNUMBER="${UMD_MAXCOMMANDBUFFERNUMBER:-256}"
    UMD_MAXCOMMANDBUFFERSIZE="${UMD_MAXCOMMANDBUFFERSIZE:-16384}"
    VLLM_HOST_OPT="$HOST_OPT_TOTAL"
    VLLM_HOST_OPT_INPUTS="$HOST_OPT_INPUTS"
    VLLM_HOST_OPT_ARENA="$HOST_OPT_ARENA"
    VLLM_HOST_OPT_BOOKKEEPING="$HOST_OPT_BOOKKEEPING"
    VLLM_HOST_OPT_POSITIONS="$HOST_OPT_POSITIONS"
    VLLM_HOST_OPT_METADATA="$HOST_OPT_METADATA"
    VLLM_HOST_OPT_DIAGNOSTICS="$HOST_OPT_DIAGNOSTICS"
)
# 基线不设置 TORCH_MODULE_ATTR_FASTPATH；compact / 采样小图也不在默认 EXTRA 里，
# 需要单项对照时见下方 COMPILATION_CONFIG_EXTRA。
# Pinned: both benchmark scripts always use the toolkit in this directory.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${HOST_TOOLKIT:-}" ]]; then
    for _cand in "$SCRIPT_DIR" "$SCRIPT_DIR/litehost_compat_slim" \
                 /home/qch/scripts/litehost_perf /home/qch/transfer/litehost_perf; do
        [[ -f "$_cand/lhctl.py" ]] && { HOST_TOOLKIT="$_cand"; break; }
    done
fi
[[ -n "${HOST_TOOLKIT:-}" ]] || { echo 'ERROR: 找不到 litehost 工具包（lhctl.py），用 HOST_TOOLKIT=<目录> 指定' >&2; exit 2; }
HOST_TOOLKIT="$(cd -- "$HOST_TOOLKIT" && pwd)"
[[ -x "$PYTHON_BIN" && -f "$HOST_TOOLKIT/lhctl.py" ]] || { echo 'ERROR: Python 或配套文件缺失' >&2; exit 2; }
[[ "$HOST_MEASURE" == lite || "$HOST_MEASURE" == off ]] || { echo 'ERROR: HOST_MEASURE=lite|off' >&2; exit 2; }
[[ "$GPUS_PER_INSTANCE" == 4 ]] || { echo 'ERROR: 此版要求四卡 TP=4, PP=1, DP=1' >&2; exit 2; }
[[ "$TEST_ID" =~ ^[A-Za-z0-9_.-]+$ && "$TEST_ID" != . && "$TEST_ID" != .. ]] || { echo 'ERROR: TEST_ID 不能包含路径分隔符' >&2; exit 2; }

BASE_DIR="$(pwd)"
RUN_DIR="${BASE_DIR}/vllmBench/${TEST_ID}"
LOG_DIR="${RUN_DIR}/logs"
SERVER_LOG="${LOG_DIR}/server.log"
SUMMARY_CSV="${RUN_DIR}/summary.csv"
SESSION_FILE="${RUN_DIR}/session.json"
PID_FILE="${RUN_DIR}/server.pid"
SERVER_PID=""; BENCH_PID=""; CLEANED=0; INIT_DONE=0

# Original case matrix: only 128/128 enabled; uncomment the others as before.
CASES=(
  "128 128"
  # "128 1024"
  # "128 2048"
  # "1024 128"
  # "1024 1024"
  # "1024 2048"
  # "2048 128"
  # "2048 1024"
  # "2048 2048"
)
# Optional text file, one 'input output' case per nonblank/non-comment line.
if [[ -n "${CASES_FILE:-}" ]]; then
    [[ -f "$CASES_FILE" ]] || { echo "ERROR: 找不到 CASES_FILE=$CASES_FILE" >&2; exit 2; }
    mapfile -t CASES < <(grep -Ev '^[[:space:]]*(#|$)' "$CASES_FILE")
fi
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
# Child processes only: drop old measurement/audit injection; keep CoreX library paths.
# 基线额外剥离调用方环境里可能残留的优化开关与 PYTHONPATH 污染。
CLEAN_ENV=(env -u PYTHONPATH -u PYTHONHOME -u LD_PRELOAD -u LD_AUDIT -u LD_DEBUG -u LD_DEBUG_OUTPUT -u LD_BIND_NOT
    -u LD_PROFILE -u VLLM_TORCH_PROFILER_DIR -u PROFILER_CONFIG -u TORCH_PROFILER_DIR
    -u VLLM_HOST_OPT -u VLLM_HOST_OPT_INPUTS -u VLLM_HOST_OPT_ARENA -u VLLM_HOST_OPT_BOOKKEEPING
    -u VLLM_HOST_OPT_POSITIONS -u VLLM_HOST_OPT_METADATA -u VLLM_HOST_OPT_ARENA_MAX_REQS
    -u VLLM_HOST_OPT_DIAGNOSTICS -u TORCH_MODULE_ATTR_FASTPATH)

SERVER_PREFIX=()
[[ -n "$CPU_RANGE" ]] && SERVER_PREFIX=(taskset -c "$CPU_RANGE")

# ------------------------------------------------------------------
# 编译配置
#   COMPILATION_CONFIG        基线，原样传给服务端（与原厂入口一致）。
#   COMPILATION_CONFIG_EXTRA  JSON 对象，合并（覆盖同名键）到基线上。
#
# 基线默认 EXTRA 为空对象：不带 compact 输出头与采样小图。需要单项对照时自行覆盖：
#   compact    COMPILATION_CONFIG_EXTRA='{"compact_greedy":true}'
#   采样小图   COMPILATION_CONFIG_EXTRA='{"sample_logits_cudagraph":true,"sample_logits_cudagraph_scope":"all_admitted","sample_logits_cudagraph_capture_sizes":[1,2,3,4,5,6,7,8],"sample_logits_cudagraph_max_bytes":67108864}'
# ------------------------------------------------------------------
COMPILATION_CONFIG='{"cudagraph_mode":"FULL_DECODE_ONLY", "mode":0}'
DEFAULT_COMPILATION_CONFIG_EXTRA='{}'
COMPILATION_CONFIG_EXTRA="${COMPILATION_CONFIG_EXTRA:-$DEFAULT_COMPILATION_CONFIG_EXTRA}"
if [[ -n "${COMPILATION_CONFIG_EXTRA:-}" ]]; then
    COMPILATION_CONFIG=$("$PYTHON_BIN" - "$COMPILATION_CONFIG" \
        "$COMPILATION_CONFIG_EXTRA" <<'PYEOF_INNER'
import json
import sys

base = json.loads(sys.argv[1])
extra = json.loads(sys.argv[2])
if not isinstance(extra, dict):
    raise SystemExit("COMPILATION_CONFIG_EXTRA must be a JSON object")
base.update(extra)
print(json.dumps(base, separators=(",", ":")))
PYEOF_INNER
    ) || { echo 'ERROR: COMPILATION_CONFIG_EXTRA 不是合法的 JSON 对象' >&2; exit 2; }
fi
echo "COMPILATION_CONFIG: $COMPILATION_CONFIG"

SERVER_ARGS=(
    -m vllm.entrypoints.openai.api_server
    --host 127.0.0.1 --port "$PORT" --model "$MODEL_PATH" --trust_remote_code --dtype auto
    --max_model_len 4096 --distributed_executor_backend mp --pipeline_parallel_size 1
    --tensor_parallel_size "$GPUS_PER_INSTANCE" --data_parallel_size 1
    --quantization compressed-tensors --gpu_memory_utilization 0.9 --kv_cache_dtype auto
    --enable_chunked_prefill --compilation-config "$COMPILATION_CONFIG"
    --async-scheduling --no-enable-prefix-caching
)
[[ "$HOST_MEASURE" == lite ]] && SERVER_ARGS+=(--worker-cls light_host_worker.LightHostWorker)

cleanup() {
    if [[ "$CLEANED" == 1 ]]; then return; fi
    CLEANED=1
    if [[ -n "$BENCH_PID" ]]; then
        "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/procutil.py" stop "$RUN_DIR/bench.process.json" || true
        wait "$BENCH_PID" 2>/dev/null || true
        BENCH_PID=""
    fi
    if [[ -n "$SERVER_PID" ]]; then
        log "停止本次服务 PID=$SERVER_PID（不使用全局 pkill）"
        "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/procutil.py" stop "$RUN_DIR/server.process.json" || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""; rm -f -- "$PID_FILE"
    fi
    if [[ "$INIT_DONE" == 1 ]]; then
        "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/lhctl.py" cleanup-control --session "$SESSION_FILE" || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "PREFIX=$PREFIX"

log "HOST_PATH=$HOST_PATH | HOST_OPT=$HOST_OPT_TOTAL | POSITIONS=$HOST_OPT_POSITIONS | ARENA=$HOST_OPT_ARENA | MIMALLOC=$MIMALLOC"
check_gpu_memory() {
    local gpu free_mib
    local -a gpus=()
    IFS=',' read -r -a gpus <<< "$GPU_LIST"
    if ! command -v ixsmi >/dev/null; then log 'WARNING: ixsmi 不可用，跳过显存预检'; return; fi
    for gpu in "${gpus[@]}"; do
        free_mib=$(ixsmi --query-gpu=memory.free --format=csv,noheader,nounits -i "$gpu" 2>/dev/null | tr -d ' ')
        if [[ "$free_mib" =~ ^[0-9]+$ ]]; then
            log "GPU $gpu: free=${free_mib} MiB（原预检阈值 20480 MiB）"
            (( free_mib >= 20480 )) || log "WARNING: GPU $gpu 显存偏低，请确认测试卡已预留"
        else log "WARNING: 无法读取 GPU $gpu 显存"; fi
    done
    return 0
}
wait_for_server() {
    local elapsed=0 code
    while (( elapsed < 600 )); do
        kill -0 "$SERVER_PID" 2>/dev/null || { log "ERROR: 服务已退出，查看 $SERVER_LOG"; return 1; }
        code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)
        [[ "$code" == 200 ]] && { log "服务就绪 (${elapsed}s)"; return 0; }
        sleep 5; elapsed=$((elapsed+5))
    done
    log 'ERROR: 服务启动超时'; return 1
}
start_server() {
    # Refuse an occupied port. Never kill an unrelated service by name/port.
    "${CLEAN_ENV[@]}" "$PYTHON_BIN" - "$PORT" <<'PY' || return 1
import socket,sys
with socket.socket() as s:s.bind(('127.0.0.1',int(sys.argv[1])))
PY
    check_gpu_memory "$GPU_LIST"
    local -a env_args=(CUDA_VISIBLE_DEVICES="$GPU_LIST" VLLM_ENFORCE_CUDA_GRAPH=1 VLLM_USE_V1=1
        "${SERVER_EXTRA_ENV[@]}")
    if [[ "$HOST_MEASURE" == lite ]]; then
        local ld_preload="$HOST_TOOLKIT/liblitehost.so"
        if [[ "$MIMALLOC" == on ]]; then
            local mimalloc_lib="${MIMALLOC_LIB:-}"
        if [[ -z "$mimalloc_lib" ]]; then
            for _m in /home/ssh_t/mimalloc-3.6.1/build/libmimalloc.so.3.6 \
                      /usr/local/lib/libmimalloc.so.3 /usr/local/lib/libmimalloc.so.2 \
                      /usr/lib/libmimalloc.so.2; do
                [[ -f "$_m" ]] && { mimalloc_lib="$_m"; break; }
            done
        fi
            if [[ -f "$mimalloc_lib" ]]; then
                ld_preload="$ld_preload:$mimalloc_lib"
                env_args+=(MIMALLOC_PURGE_DELAY="${MIMALLOC_PURGE_DELAY:-5000}"
                    MIMALLOC_ARENA_IS_NUMA_LOCAL="${MIMALLOC_ARENA_IS_NUMA_LOCAL:-1}"
                    MALLOCSTATS="${MALLOCSTATS:-1}")
            else
                log "WARNING: mimalloc 库不存在，跳过注入：$mimalloc_lib"
            fi
        fi
        env_args+=(PYTHONPATH="${HOST_TOOLKIT}${PYTHONPATH:+:$PYTHONPATH}"
            LD_PRELOAD="$ld_preload"
            LIGHTHOST_LIB="$HOST_TOOLKIT/liblitehost.so" LIGHTHOST_SESSION="$SESSION_FILE")
    fi
    "${CLEAN_ENV[@]}" "${env_args[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/procutil.py" exec "$RUN_DIR/server.process.json" -- \
        "${SERVER_PREFIX[@]}" "$PYTHON_BIN" "${SERVER_ARGS[@]}" >> "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!; echo "$SERVER_PID" > "$PID_FILE"
    log "服务 PID=$SERVER_PID；所有 case 复用；日志=$SERVER_LOG"
    wait_for_server
}
run_case() {
    local input_len="$1" output_len="$2"
    local case_id="bs${MAX_CONCURRENCY}_in${input_len}_out${output_len}"
    local case_log="${LOG_DIR}/bench_${case_id}.log" case_dir="${RUN_DIR}/litehost/${case_id}"
    local -a client env_args
    env_args=()
    if [[ "$HOST_MEASURE" == lite ]]; then
        "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/lhctl.py" prepare --session "$SESSION_FILE" \
            --case-id "$case_id" --num-prompts "$NUM_PROMPTS" --input-len "$input_len" --output-len "$output_len" || return 1
        client=("$HOST_TOOLKIT/bench_driver.py")
        env_args=(LIGHTHOST_SESSION="$SESSION_FILE" LIGHTHOST_CASE_DIR="$case_dir")
    else
        client=(-m vllm.entrypoints.cli.main bench serve)
    fi
    log "==== $case_id | mode=$HOST_MEASURE | warmup=$NUM_WARMUPS | 同一服务 ===="
    "${CLEAN_ENV[@]}" "${env_args[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/procutil.py" exec "$RUN_DIR/bench.process.json" -- \
        "$PYTHON_BIN" "${client[@]}" \
        --backend vllm \
        --num_prompts "$NUM_PROMPTS" --num-warmups "$NUM_WARMUPS" --max-concurrency "$MAX_CONCURRENCY" \
        --dataset_name random --random_input_len "$input_len" --random_output_len "$output_len" \
        --host 127.0.0.1 --port "$PORT" --model "$MODEL_PATH" --trust_remote_code \
        --ignore_eos --top_p 1 --top_k -1 --temperature 0 --seed 42 \
        --save-result --result-dir "$RUN_DIR" --result_filename "${case_id}.json" > "$case_log" 2>&1 &
    BENCH_PID=$!
    local rc=0
    wait "$BENCH_PID" || rc=$?
    BENCH_PID=""
    if (( rc != 0 )); then log "ERROR: case 失败 rc=$rc；查看 $case_log"; return "$rc"; fi
    if [[ "$HOST_MEASURE" == lite ]]; then
        "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/lhctl.py" finish "$case_dir" \
            --link-percent "$HOST_LINK_PERCENT" || return 1
    fi
    log "完成 $case_id → ${RUN_DIR}/${case_id}.json"
}

# Validate cheap inputs before model initialization.
"${CLEAN_ENV[@]}" "$PYTHON_BIN" - "$GPU_LIST" "$NUM_PROMPTS" "$NUM_WARMUPS" "$MAX_CONCURRENCY" "$HOST_LINK_PERCENT" "$CASE_INTERVAL" "${CASES[@]}" <<'PY' || exit 2
import math,sys
ids,n,w,c,p,interval,*cases=sys.argv[1:]
if len(ids.split(','))!=4 or len(set(ids.split(',')))!=4:raise ValueError('需要四张不同 GPU')
if int(n)<=0 or int(w)<0 or int(c)<=0:raise ValueError('请求/预热/并发参数无效')
if not math.isfinite(float(p)) or not 0<=float(p)<=100 or float(interval)<0:raise ValueError('系数或间隔无效')
if not cases or len(cases)!=len(set(cases)):raise ValueError('case 列表为空或重复')
for x in cases:
    parts=x.split()
    if len(parts)!=2 or min(map(int,parts))<=0 or sum(map(int,parts))>4096:raise ValueError('case 需要两个正整数且总长 <= 4096')
PY
log "TEST_ID=$TEST_ID | MODE=$HOST_MEASURE | WARMUP=$NUM_WARMUPS | CPU_RANGE=$CPU_RANGE"
log "prefix cache=OFF | backend=vllm | 同一服务运行 ${#CASES[@]} 个 case | RUN_DIR=$RUN_DIR"
if [[ "$HOST_DRY_RUN" == 1 ]]; then
    printf 'SERVER: '; printf '%q ' "${SERVER_PREFIX[@]}" "$PYTHON_BIN" "${SERVER_ARGS[@]}"; printf '\n'
    printf 'CASES: '; printf '%s; ' "${CASES[@]}"; printf '\n'
    exit 0
fi
[[ -d "$MODEL_PATH" ]] || { log 'ERROR: MODEL_PATH 不是本地目录'; exit 2; }
if [[ -e "$RUN_DIR" ]]; then log 'ERROR: RUN_DIR 已存在，请换一个 TEST_ID，避免混入旧文件'; exit 2; fi
mkdir -p "$LOG_DIR"
{
    echo "test_id=$TEST_ID"
    echo "started=$(date -Is)"
    echo "prefix=$PREFIX"
    echo "multi_engine=$(cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null || echo unknown)"
    echo "cpu_range=$CPU_RANGE"
    echo "hotspot_opt=${HOTSPOT_OPT:-unset}"
    echo "model_path=$MODEL_PATH"
    echo "gpus=$GPU_LIST tp=$GPUS_PER_INSTANCE"
    echo "prompts=$NUM_PROMPTS concurrency=$MAX_CONCURRENCY warmups=$NUM_WARMUPS"

    echo "host_path=$HOST_PATH host_measure=$HOST_MEASURE mimalloc=$MIMALLOC"
    echo "host_opt=$HOST_OPT_TOTAL inputs=$HOST_OPT_INPUTS arena=$HOST_OPT_ARENA bookkeeping=$HOST_OPT_BOOKKEEPING positions=$HOST_OPT_POSITIONS metadata=$HOST_OPT_METADATA diagnostics=$HOST_OPT_DIAGNOSTICS"
    echo "compilation_config=$COMPILATION_CONFIG"
} > "$RUN_DIR/config.txt" 2>/dev/null || true
if [[ "$HOST_MEASURE" == lite ]]; then
    "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/lhctl.py" init --run-dir "$RUN_DIR" \
        --timeout "$HOST_TIMEOUT" --max-scopes "$HOST_MAX_SCOPES" > "$LOG_DIR/preflight.log" 2>&1 || { cat "$LOG_DIR/preflight.log"; exit 2; }
    INIT_DONE=1
fi
if ! start_server; then log 'FATAL: 启动失败'; exit 1; fi
FAILED=0
for idx in "${!CASES[@]}"; do
    read -r input_len output_len <<< "${CASES[$idx]}"
    if ! run_case "$input_len" "$output_len"; then
        FAILED=1; log '停止后续 case，避免未完成请求或测量状态污染下一轮'; break
    fi
    if (( idx < ${#CASES[@]}-1 )); then log "等待 ${CASE_INTERVAL}s"; sleep "$CASE_INTERVAL"; fi
done
# Intermediate case results have already been validated and saved by
# lhctl.py finish (quietly). Build all-case CSV + Host report SILENTLY;
# print both result summaries only ONCE, after all cases and server cleanup.
if ! "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/lhctl.py" summary "$RUN_DIR" \
        > "$LOG_DIR/summary_build.log"; then
    FAILED=1
fi
if [[ "$HOST_MEASURE" == lite && "$FAILED" == 0 ]]; then
    "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/analyze_litehost.py" "$RUN_DIR/litehost" \
        --link-percent "$HOST_LINK_PERCENT" --out "$RUN_DIR/host_summary" --quiet || FAILED=1
fi
cleanup
(( FAILED == 0 )) || { log "部分失败，保留诊断：$RUN_DIR"; exit 2; }

log "========== 所有 case 最终结果（仅此处打印一次） =========="
"${CLEAN_ENV[@]}" "$PYTHON_BIN" - "$SUMMARY_CSV" "$MAX_CONCURRENCY" "${CASES[@]}" <<'PY' || exit 2
import csv,sys
from pathlib import Path
path=Path(sys.argv[1]);bs=sys.argv[2]
with path.open(newline='') as f:
    rows={r['case']:r for r in csv.DictReader(f)}
print('===== Benchmark：吞吐与延迟（全部 case）=====')
for spec in sys.argv[3:]:
    in_len,out_len=spec.split()
    case=f'bs{bs}_in{in_len}_out{out_len}'
    if case not in rows:raise SystemExit(f'ERROR: summary.csv 缺少 {case}')
    r=rows[case]
    def fmt(key):
        val=r.get(key,'')
        try:return f'{float(val):.3f}'
        except (TypeError,ValueError):return 'N/A'
    print(f'{case}: output_tok/s={fmt("output_token_throughput_tok_s")} '
          f'TTFT_mean={fmt("mean_ttft_ms")}ms '
          f'TPOT_mean={fmt("mean_tpot_ms")}ms ITL_mean={fmt("mean_itl_ms")}ms')
PY
if [[ "$HOST_MEASURE" == lite ]]; then
    echo '===== LiteHost：四 rank、所有 case 的 H 与 H+G ====='
    cat "$RUN_DIR/host_summary/report.txt"
fi
log "全部完成 | benchmark=$SUMMARY_CSV | host=$([[ "$HOST_MEASURE" == lite ]] && echo "$RUN_DIR/host_summary/report.txt" || echo 'OFF/未采集')"

