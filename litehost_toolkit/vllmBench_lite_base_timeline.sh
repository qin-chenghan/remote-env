#!/usr/bin/env bash
# Adapted from the uploaded vllmBench_lite.sh. Keep one server for all cases.
# Defaults retained: warmups=16, cache OFF, CPUs 192-255 (NUMA node 3), backend=vllm.
# Requires the matching files in this slim folder (included in the ZIP).
#
# 32 base timeline：服务参数、SERVER_EXTRA_ENV、case、prompts、warmups、并发、seed
# 与 32 的 vllmBench_lite_base.sh 保持一致，只加 torch profiler 相关行。
#
# 为什么必须 HOST_MEASURE=off：lite 测量层与 torch profiler 互斥——
#   bench_driver.py:67      `if bind.arguments.get('profile'): raise ValueError('Torch profiler must be disabled')`
#   light_host_worker.py:12 `if getattr(self,'profiler',None): raise RuntimeError('Disable Torch Profiler for Lite measurement')`
# 所以 trace 只能用默认 worker + vllm bench serve --profile 采集。
set -uo pipefail

MODEL_PATH="${MODEL_PATH:-/home/model/ts/Qwen3-32B-W8A8}"
if [[ -z "${MOCK_DIR:-}" && ! -e /dev/iluvatar0 ]]; then
    MOCK_DIR=/home/qch/mock_vllm
fi
_timeline_prefix=timeline
_timeline_port=8848
_timeline_cpu_range=192-255
if [[ -n "${MOCK_DIR:-}" ]]; then
    _timeline_prefix=mocktimeline
    _timeline_port=8948
    _timeline_cpu_range=0-63
fi
TEST_ID="${TEST_ID:-"${_timeline_prefix}_$(date +%Y%m%d_%H%M%S)"}"
# JIT artifacts outlive /tmp cleanup and container restarts.
export TORCHINDUCTOR_CACHE_DIR="${TORCHINDUCTOR_CACHE_DIR:-/home/huawei_ts_program/inductor_cache_py311}"
mkdir -p "$TORCHINDUCTOR_CACHE_DIR" 2>/dev/null || true
PREFIX="${PREFIX:-/opt/corex311}"
PYTHON_BIN="${PYTHON_BIN:-${PREFIX}/bin/python3}"
GPU_LIST="${GPU_LIST:-0,1,2,3}"
GPUS_PER_INSTANCE="${GPUS_PER_INSTANCE:-4}"
PORT="${PORT:-$_timeline_port}"
NUM_PROMPTS="${NUM_PROMPTS:-100}"
NUM_WARMUPS="${NUM_WARMUPS:-16}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-8}"
CASE_INTERVAL="${CASE_INTERVAL:-60}"
CPU_RANGE="${CPU_RANGE-$_timeline_cpu_range}"
HOST_MEASURE="${HOST_MEASURE:-off}"         # 本脚本要求 off；lite 与 torch profiler 互斥
SERVER_WAIT_TIMEOUT="${SERVER_WAIT_TIMEOUT:-0}"   # 0 = 不设上限，直到服务就绪或进程退出
HOST_LINK_PERCENT="${HOST_LINK_PERCENT:-0}" # 5 means 5%, computed offline
HOST_TIMEOUT="${HOST_TIMEOUT:-120}"
HOST_MAX_SCOPES="${HOST_MAX_SCOPES:-200000}"
HOST_DRY_RUN="${HOST_DRY_RUN:-0}"
PROFILE="${PROFILE:-1}"                     # 1=开 torch profiler 出 trace
PROFILE_DELAY_ITERATIONS="${PROFILE_DELAY_ITERATIONS:-0}"
PROFILE_MAX_ITERATIONS="${PROFILE_MAX_ITERATIONS:-0}"
PROFILE_WARMUP_ITERATIONS="${PROFILE_WARMUP_ITERATIONS:-0}"
PROFILE_ACTIVE_ITERATIONS="${PROFILE_ACTIVE_ITERATIONS:-2000}"
PROFILE_FLUSH_TIMEOUT="${PROFILE_FLUSH_TIMEOUT:-300}"
VLLM_RPC_TIMEOUT="${VLLM_RPC_TIMEOUT:-1800000}"
SERVER_EXTRA_ENV=(
    UMD_MAXCOMMANDBUFFERNUMBER=256
    UMD_MAXCOMMANDBUFFERSIZE=16384
)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# 脚本与 lhctl.py 同目录时直接用脚本所在目录；否则退回脚本旁的 slim 包，再退回固定路径。
if [[ -z "${HOST_TOOLKIT:-}" ]]; then
    if [[ -f "$SCRIPT_DIR/lhctl.py" ]]; then
        HOST_TOOLKIT="$SCRIPT_DIR"
    elif [[ -f "$SCRIPT_DIR/litehost_compat_slim/lhctl.py" ]]; then
        HOST_TOOLKIT="$SCRIPT_DIR/litehost_compat_slim"
    else
        HOST_TOOLKIT=/home/huawei_ts_program/litehost_perf_opt
    fi
fi
HOST_TOOLKIT="$(cd -- "$HOST_TOOLKIT" 2>/dev/null && pwd)" || { echo 'ERROR: 设置 HOST_TOOLKIT 或解压完整 litehost_compat_slim_v041.zip' >&2; exit 2; }
[[ -x "$PYTHON_BIN" && -f "$HOST_TOOLKIT/lhctl.py" ]] || { echo 'ERROR: Python 或配套文件缺失' >&2; exit 2; }
[[ "$HOST_MEASURE" == lite || "$HOST_MEASURE" == off ]] || { echo 'ERROR: HOST_MEASURE=lite|off' >&2; exit 2; }
[[ "$PROFILE" == 0 || "$PROFILE" == 1 ]] || { echo 'ERROR: PROFILE=0|1' >&2; exit 2; }
if [[ "$PROFILE" == 1 && "$HOST_MEASURE" != off ]]; then
    echo 'ERROR: lite 测量层与 torch profiler 互斥（bench_driver.py 与 LightHostWorker 都会拒绝）；PROFILE=1 时必须 HOST_MEASURE=off' >&2
    exit 2
fi
[[ "$GPUS_PER_INSTANCE" == 4 ]] || { echo 'ERROR: 此版要求四卡 TP=4, PP=1, DP=1' >&2; exit 2; }
[[ "$TEST_ID" =~ ^[A-Za-z0-9_.-]+$ && "$TEST_ID" != . && "$TEST_ID" != .. ]] || { echo 'ERROR: TEST_ID 不能包含路径分隔符' >&2; exit 2; }

BASE_DIR="$(pwd)"
RUN_DIR="${BASE_DIR}/vllmBench/${TEST_ID}"
LOG_DIR="${RUN_DIR}/logs"
SERVER_LOG="${LOG_DIR}/server.log"
SUMMARY_CSV="${RUN_DIR}/summary.csv"
SESSION_FILE="${RUN_DIR}/session.json"
PID_FILE="${RUN_DIR}/server.pid"
PROFILE_DIR="${RUN_DIR}/timeline"
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
# base：同时剥离调用方环境里可能残留的 host-opt 开关。
CLEAN_ENV=(env -u PYTHONPATH -u PYTHONHOME -u LD_PRELOAD -u LD_AUDIT -u LD_DEBUG -u LD_DEBUG_OUTPUT -u LD_BIND_NOT
    -u LD_PROFILE -u VLLM_TORCH_PROFILER_DIR -u PROFILER_CONFIG -u TORCH_PROFILER_DIR
    -u VLLM_HOST_OPT -u VLLM_HOST_OPT_INPUTS -u VLLM_HOST_OPT_ARENA -u VLLM_HOST_OPT_BOOKKEEPING
    -u VLLM_HOST_OPT_POSITIONS -u VLLM_HOST_OPT_ARENA_MAX_REQS -u VLLM_HOST_OPT_DIAGNOSTICS)
SERVER_PREFIX=()
[[ -n "$CPU_RANGE" ]] && SERVER_PREFIX=(taskset -c "$CPU_RANGE")
SERVER_ARGS=(
    -m vllm.entrypoints.openai.api_server
    --host 127.0.0.1 --port "$PORT" --model "$MODEL_PATH" --trust_remote_code --dtype auto
    --max_model_len 4096 --distributed_executor_backend mp --pipeline_parallel_size 1
    --tensor_parallel_size "$GPUS_PER_INSTANCE" --data_parallel_size 1
    --quantization compressed-tensors --gpu_memory_utilization 0.9 --kv_cache_dtype auto
    --enable_chunked_prefill --compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY", "mode":0}'
    --async-scheduling --no-enable-prefix-caching
)
# torch_profiler_dir 必须是绝对路径（vLLM 以 server 进程 cwd 解析相对路径）。
PROFILER_CONFIG_JSON=''
if [[ "$PROFILE" == 1 ]]; then
    PROFILER_CONFIG_JSON=$(cat <<EOF
{"profiler":"torch","torch_profiler_dir":"${PROFILE_DIR}","delay_iterations":${PROFILE_DELAY_ITERATIONS},"max_iterations":${PROFILE_MAX_ITERATIONS},"warmup_iterations":${PROFILE_WARMUP_ITERATIONS},"active_iterations":${PROFILE_ACTIVE_ITERATIONS},"ignore_frontend":true}
EOF
)
    PROFILER_CONFIG_JSON="$(echo "$PROFILER_CONFIG_JSON" | tr -d '\n')"
    SERVER_ARGS+=(--profiler-config "$PROFILER_CONFIG_JSON")
fi
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
        if [[ "$PROFILE" == 1 ]]; then
            # torch profiler 在停服时落盘；procutil.py stop 只等 10s 就 SIGKILL，这里给足时间。
            kill -TERM -- -"$SERVER_PID" 2>/dev/null || true
            local_i=0
            while (( local_i < PROFILE_FLUSH_TIMEOUT / 3 )); do
                kill -0 "$SERVER_PID" 2>/dev/null || break
                sleep 3; local_i=$((local_i+1))
            done
            if kill -0 "$SERVER_PID" 2>/dev/null; then
                log "WARNING: ${PROFILE_FLUSH_TIMEOUT}s 内未退出，SIGKILL"
                kill -KILL -- -"$SERVER_PID" 2>/dev/null || true
            fi
            wait "$SERVER_PID" 2>/dev/null || true
            "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/procutil.py" stop "$RUN_DIR/server.process.json" || true
        else
            "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/procutil.py" stop "$RUN_DIR/server.process.json" || true
            wait "$SERVER_PID" 2>/dev/null || true
        fi
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
log "inductor_cache=$TORCHINDUCTOR_CACHE_DIR files=$(find "$TORCHINDUCTOR_CACHE_DIR" -name '*.py' 2>/dev/null | wc -l)"

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
    # No fixed cap: graph capture on a cold JIT cache can take tens of minutes.
    # Set SERVER_WAIT_TIMEOUT > 0 to restore a limit.
    local elapsed=0 code
    while :; do
        kill -0 "$SERVER_PID" 2>/dev/null || { log "ERROR: 服务已退出，查看 $SERVER_LOG"; return 1; }
        code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)
        [[ "$code" == 200 ]] && { log "服务就绪 (${elapsed}s)"; return 0; }
        if (( SERVER_WAIT_TIMEOUT > 0 && elapsed >= SERVER_WAIT_TIMEOUT )); then
            log "ERROR: 服务启动超时 (${SERVER_WAIT_TIMEOUT}s)"; return 1
        fi
        (( elapsed > 0 && elapsed % 300 == 0 )) && log "等待服务中 (${elapsed}s)"
        sleep 5; elapsed=$((elapsed+5))
    done
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
    env_args+=(VLLM_RPC_TIMEOUT="$VLLM_RPC_TIMEOUT")
    if [[ -n "$MOCK_DIR" ]]; then
        [[ -d "$MOCK_DIR/mock_gpu" ]] || { echo "ERROR: MOCK_DIR 无效: $MOCK_DIR" >&2; return 1; }
        env_args+=(PYTHONPATH="$MOCK_DIR")
    fi
    if [[ "$HOST_MEASURE" == lite ]]; then
        env_args+=(PYTHONPATH="$HOST_TOOLKIT"
            LD_PRELOAD="$HOST_TOOLKIT/liblitehost.so"
            LIGHTHOST_LIB="$HOST_TOOLKIT/liblitehost.so" LIGHTHOST_SESSION="$SESSION_FILE")
    fi
    "${CLEAN_ENV[@]}" "${env_args[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/procutil.py" exec "$RUN_DIR/server.process.json" -- \
        "${SERVER_PREFIX[@]}" "$PYTHON_BIN" "${SERVER_ARGS[@]}" >> "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!; echo "$SERVER_PID" > "$PID_FILE"
    log "服务 PID=$SERVER_PID；所有 case 复用；日志=$SERVER_LOG"
    wait_for_server || return 1
    if [[ "$PROFILE" == 1 ]]; then
        if grep -qE "Profiler with mode|Torch profiling enabled" "$SERVER_LOG" 2>/dev/null; then
            log "profiler 已生效：$PROFILER_CONFIG_JSON"
        else
            log "WARNING: server.log 里没找到 profiler 关键字，确认 --profiler-config 已生效"
        fi
    fi
    return 0
}
run_case() {
    local input_len="$1" output_len="$2"
    local case_id="bs${MAX_CONCURRENCY}_in${input_len}_out${output_len}"
    local case_log="${LOG_DIR}/bench_${case_id}.log" case_dir="${RUN_DIR}/litehost/${case_id}"
    local -a client env_args profile_args
    env_args=(); profile_args=()
    if [[ "$HOST_MEASURE" == lite ]]; then
        "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/lhctl.py" prepare --session "$SESSION_FILE" \
            --case-id "$case_id" --num-prompts "$NUM_PROMPTS" --input-len "$input_len" --output-len "$output_len" || return 1
        client=("$HOST_TOOLKIT/bench_driver.py")
        env_args=(LIGHTHOST_SESSION="$SESSION_FILE" LIGHTHOST_CASE_DIR="$case_dir")
    else
        client=(-m vllm.entrypoints.cli.main bench serve)
        [[ "$PROFILE" == 1 ]] && profile_args=(--profile)
    fi
    log "==== $case_id | mode=$HOST_MEASURE | profile=$PROFILE | warmup=$NUM_WARMUPS | 同一服务 ===="
    "${CLEAN_ENV[@]}" "${env_args[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/procutil.py" exec "$RUN_DIR/bench.process.json" -- \
        "$PYTHON_BIN" "${client[@]}" \
        --backend vllm \
        --num_prompts "$NUM_PROMPTS" --num-warmups "$NUM_WARMUPS" --max-concurrency "$MAX_CONCURRENCY" \
        --dataset_name random --random_input_len "$input_len" --random_output_len "$output_len" \
        --host 127.0.0.1 --port "$PORT" --model "$MODEL_PATH" --trust_remote_code \
        --ignore_eos --top_p 1 --top_k -1 --temperature 0 --seed 42 \
        "${profile_args[@]}" \
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
log "TEST_ID=$TEST_ID | MODE=$HOST_MEASURE | PROFILE=$PROFILE | WARMUP=$NUM_WARMUPS | CPU_RANGE=$CPU_RANGE"
log "prefix cache=OFF | backend=vllm | 同一服务运行 ${#CASES[@]} 个 case | RUN_DIR=$RUN_DIR"
if [[ "$HOST_DRY_RUN" == 1 ]]; then
    printf 'SERVER: '; printf '%q ' "${SERVER_PREFIX[@]}" "$PYTHON_BIN" "${SERVER_ARGS[@]}"; printf '\n'
    printf 'CASES: '; printf '%s; ' "${CASES[@]}"; printf '\n'
    exit 0
fi
[[ -d "$MODEL_PATH" ]] || { log 'ERROR: MODEL_PATH 不是本地目录'; exit 2; }
if [[ -e "$RUN_DIR" ]]; then log 'ERROR: RUN_DIR 已存在，请换一个 TEST_ID，避免混入旧文件'; exit 2; fi
mkdir -p "$LOG_DIR"
[[ "$PROFILE" == 1 ]] && mkdir -p "$PROFILE_DIR"
{
    echo "test_id=$TEST_ID"
    echo "started=$(date -Is)"
    echo "prefix=$PREFIX"
    echo "multi_engine=$(cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null || echo unknown)"
    echo "cpu_range=$CPU_RANGE"
    echo "hotspot_opt=${HOTSPOT_OPT:-unset}"
    echo "model_path=$MODEL_PATH"
    echo "gpus=$GPU_LIST tp=$GPUS_PER_INSTANCE"
    echo "mock_dir=${MOCK_DIR:-none}"
    echo "prompts=$NUM_PROMPTS concurrency=$MAX_CONCURRENCY warmups=$NUM_WARMUPS"
    echo "host_measure=$HOST_MEASURE profile=$PROFILE profile_dir=$PROFILE_DIR"
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
# profiler 可能在停服时才落盘（timeline_opt.sh 里 flush 要几分钟），停服后最多等 180s。
if [[ "$PROFILE" == 1 && "$FAILED" == 0 ]]; then
    local_i=0
    while (( local_i < 60 )); do
        if find "$PROFILE_DIR" -type f \( -name '*.json' -o -name '*.json.gz' \) 2>/dev/null | grep -q .; then break; fi
        sleep 3; local_i=$((local_i+1))
    done
    if find "$PROFILE_DIR" -type f \( -name '*.json' -o -name '*.json.gz' \) 2>/dev/null | grep -q .; then
        log "trace 已产出：$(find "$PROFILE_DIR" -type f | wc -l) 个文件"
    else
        log "ERROR: 等待 180s 后 $PROFILE_DIR 仍无 trace 文件，检查 --profiler-config 与 bench --profile"; FAILED=1
    fi
fi
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
if [[ "$PROFILE" == 1 ]]; then
    echo '===== Timeline 产物 ====='
    find "$PROFILE_DIR" -type f 2>/dev/null | head -50
    echo "Timeline 目录(Perfetto JSON): $PROFILE_DIR"
fi
log "全部完成 | benchmark=$SUMMARY_CSV | host=$([[ "$HOST_MEASURE" == lite ]] && echo "$RUN_DIR/host_summary/report.txt" || echo 'OFF/未采集')"
