#!/usr/bin/env bash
# =============================================================================
# timeline_ixsys_base.sh - 基线负载 + ixsys timeline 采集
#
# 负载口径的唯一来源是 vllmBench_lite_base.sh：
#   - 服务端参数与 SERVER_EXTRA_ENV 完全相同（PREFIX=/opt/corex311、host opt 全 off、
#     不注入 mimalloc、COMPILATION_CONFIG_EXTRA={}）
#   - bench 客户端参数完全相同：100 prompts / warmup 16 / 并发 8 / random 128-128 /
#     seed 42 / temperature 0 / ignore_eos / 同一 case_id 命名
#   - CPU 绑定 192-255、端口 8848、间隔 60s、结果写 vllmBench/<TEST_ID>/<case>.json
#
# 与 vllmBench 的唯一差异：采样层从 litehost 换成 ixsys。
#   litehost 需要 --worker-cls LightHostWorker + liblitehost.so 注入，属于被测链路；
#   ixsys 在外部包裹服务进程，不进入 vLLM 代码路径。
#
# ixsys 只能在整个进程启动时包裹，无法按 bench 阶段起停，因此按 case 重启服务，
# 每个 case 产出一份独立 .ptrace（默认矩阵只有 128/128 一个 case，与 vllmBench
# 的“单服务跑完”等价）。
#
# 部署与运行（容器内）：
#   docker exec corex5-py311 bash -lc
#   cd /home/huawei_ts_program/litehost_perf_opt
#   ./timeline_ixsys_base.sh
#
# 可选环境变量：
#   TEST_ID / PREFIX / PYTHON_BIN / GPU_LIST / PORT / NUM_PROMPTS / NUM_WARMUPS /
#   MAX_CONCURRENCY / CASE_INTERVAL / CPU_RANGE / HOST_DRY_RUN /
#   IXSYS_BIN / IXSYS_TRACE / IXSYS_DEFER / IXSYS_LIMIT / IXSYS_PRINT_API /
#   IXSYS_PRINT_GPU / IXSYS_NCCL / IXSYS_GPU_METRICS / IXSYS_CALLSTACK / IXSYS_VERBOSE
#
# 注意：ixsys 进程本身不能带 LD_PRELOAD（实测 SIGSEGV），脚本外层统一 unset；
#       需要注入的分配器只在应用命令（内层 env）上设置。
# =============================================================================
set -uo pipefail

MODEL_PATH="${MODEL_PATH:-/home/hc/modules/Qwen3-32B-W8A8}"
TEST_ID="${TEST_ID:-"vllmBase_ixsys_$(date +%Y%m%d_%H%M%S)"}"
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
HOST_MEASURE="${HOST_MEASURE:-off}"         # 采样由 ixsys 完成；lite 与外部 trace 互斥
HOST_DRY_RUN="${HOST_DRY_RUN:-0}"

# ============ ixsys 采集参数 ============
IXSYS_BIN="${IXSYS_BIN:-/usr/local/corex/bin/ixsys}"
IXSYS_TRACE="${IXSYS_TRACE:-cuda}"          # -t；cuda 已含 cuda_api + cuda_device
IXSYS_DEFER="${IXSYS_DEFER:-0}"             # -d 秒，延迟采集（0=启动即抓）
IXSYS_LIMIT="${IXSYS_LIMIT:-0}"             # -l 秒，限时采集（0=不限，停止靠结束应用）
IXSYS_PRINT_API="${IXSYS_PRINT_API:-1}"
IXSYS_PRINT_GPU="${IXSYS_PRINT_GPU:-1}"
IXSYS_NCCL="${IXSYS_NCCL:-0}"
IXSYS_GPU_METRICS="${IXSYS_GPU_METRICS:-0}"
IXSYS_CALLSTACK="${IXSYS_CALLSTACK:-0}"
IXSYS_VERBOSE="${IXSYS_VERBOSE:-1}"

# ------------------------------------------------------------------
# 优化开关组（与 vllmBench_lite_base.sh 相同：基线默认全关）。
# ------------------------------------------------------------------
HOST_PATH="${HOST_PATH:-off}"
MIMALLOC="${MIMALLOC:-off}"

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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${HOST_TOOLKIT:-}" ]]; then
    for _cand in "$SCRIPT_DIR" "$SCRIPT_DIR/litehost_compat_slim" \
                 /home/qch/scripts/litehost_perf /home/qch/transfer/litehost_perf; do
        [[ -f "$_cand/procutil.py" ]] && { HOST_TOOLKIT="$_cand"; break; }
    done
fi
[[ -n "${HOST_TOOLKIT:-}" ]] || { echo 'ERROR: 找不到 litehost 工具包（procutil.py），用 HOST_TOOLKIT=<目录> 指定' >&2; exit 2; }
HOST_TOOLKIT="$(cd -- "$HOST_TOOLKIT" && pwd)"
[[ -x "$PYTHON_BIN" && -f "$HOST_TOOLKIT/procutil.py" ]] || { echo 'ERROR: Python 或配套文件缺失' >&2; exit 2; }
[[ -x "$IXSYS_BIN" ]] || { echo "ERROR: ixsys 不存在: $IXSYS_BIN" >&2; exit 2; }
[[ "$HOST_MEASURE" == off ]] || { echo 'ERROR: 本脚本用 ixsys 采样，HOST_MEASURE 必须为 off' >&2; exit 2; }
[[ "$GPUS_PER_INSTANCE" == 4 ]] || { echo 'ERROR: 此版要求四卡 TP=4, PP=1, DP=1' >&2; exit 2; }
[[ "$TEST_ID" =~ ^[A-Za-z0-9_.-]+$ && "$TEST_ID" != . && "$TEST_ID" != .. ]] || { echo 'ERROR: TEST_ID 不能包含路径分隔符' >&2; exit 2; }

BASE_DIR="$(pwd)"
RUN_DIR="${BASE_DIR}/vllmBench/${TEST_ID}"
LOG_DIR="${RUN_DIR}/logs"
TRACE_ROOT="${RUN_DIR}/ixsys"
SERVER_LOG="${LOG_DIR}/server.log"
SUMMARY_CSV="${RUN_DIR}/summary.csv"
IXSYS_PID=""; BENCH_PID=""; CLEANED=0

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
if [[ -n "${CASES_FILE:-}" ]]; then
    [[ -f "$CASES_FILE" ]] || { echo "ERROR: 找不到 CASES_FILE=$CASES_FILE" >&2; exit 2; }
    mapfile -t CASES < <(grep -Ev '^[[:space:]]*(#|$)' "$CASES_FILE")
fi
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Child processes only: drop old measurement/audit injection; keep CoreX library paths.
# 基线额外剥离调用方环境里可能残留的优化开关与 PYTHONPATH 污染。
# LD_PRELOAD 必须从 ixsys 侧剥掉（ixsys 带 preload 启动会 SIGSEGV），分配器只在应用侧注入。
CLEAN_ENV=(env -u PYTHONPATH -u PYTHONHOME -u LD_PRELOAD -u LD_AUDIT -u LD_DEBUG -u LD_DEBUG_OUTPUT -u LD_BIND_NOT
    -u LD_PROFILE -u VLLM_TORCH_PROFILER_DIR -u PROFILER_CONFIG -u TORCH_PROFILER_DIR
    -u VLLM_HOST_OPT -u VLLM_HOST_OPT_INPUTS -u VLLM_HOST_OPT_ARENA -u VLLM_HOST_OPT_BOOKKEEPING
    -u VLLM_HOST_OPT_POSITIONS -u VLLM_HOST_OPT_METADATA -u VLLM_HOST_OPT_ARENA_MAX_REQS
    -u VLLM_HOST_OPT_DIAGNOSTICS -u TORCH_MODULE_ATTR_FASTPATH)

SERVER_PREFIX=()
[[ -n "$CPU_RANGE" ]] && SERVER_PREFIX=(taskset -c "$CPU_RANGE")

# ------------------------------------------------------------------
# 编译配置（与 vllmBench_lite_base.sh 相同的基线与合并逻辑）
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
# ixsys 会把应用参数按空白重新切分，JSON 内不能留空格。
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
# 采样由 ixsys 完成，不传 --worker-cls（litehost worker 属于被替换的测量层）。

build_ixsys_args() {
    local args=(-o "$1" -t "$IXSYS_TRACE")
    if (( IXSYS_DEFER > 0 )); then args+=(-d "$IXSYS_DEFER"); fi
    if (( IXSYS_LIMIT > 0 )); then args+=(-l "$IXSYS_LIMIT"); fi
    [[ "$IXSYS_PRINT_API" == 1 ]] && args+=(--print-api-summary)
    [[ "$IXSYS_PRINT_GPU" == 1 ]] && args+=(--print-gpu-summary)
    [[ "$IXSYS_NCCL" == 1 ]] && args+=(--nccl-trace coll,kernel-launch)
    [[ "$IXSYS_GPU_METRICS" == 1 ]] && args+=(--gpu-metrics-device all)
    [[ "$IXSYS_CALLSTACK" == 1 ]] && args+=(-c)
    printf '%s\n' "${args[@]}"
}

# 应用命令：外层 env 负责剥离/注入环境，ixsys 只当它是普通子进程。
# 基线 MIMALLOC=off，expand 为空；opt 版在同一函数里按 MIMALLOC 注入。
build_app_cmd() {
    local -n _app_out=$1
    _app_out=(env)
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
            _app_out+=(LD_PRELOAD="$mimalloc_lib"
                MIMALLOC_PURGE_DELAY="${MIMALLOC_PURGE_DELAY:-5000}"
                MIMALLOC_ARENA_IS_NUMA_LOCAL="${MIMALLOC_ARENA_IS_NUMA_LOCAL:-1}"
                MALLOCSTATS="${MALLOCSTATS:-1}")
        else
            log "WARNING: mimalloc 库不存在，跳过注入：$mimalloc_lib"
        fi
    fi
    _app_out+=("$PYTHON_BIN" "${SERVER_ARGS[@]}")
}

descendants() {
    local root="$1" child
    for child in $(pgrep -P "$root" 2>/dev/null); do
        echo "$child"
        descendants "$child"
    done
}

# 只认 ixsys 的后代进程，避免 pgrep -f 误命中 ixsys 自身或别的服务实例。
app_pids() {
    local p
    for p in $(descendants "$IXSYS_PID"); do
        [[ -r "/proc/$p/cmdline" ]] || continue
        if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'vllm.entrypoints.openai.api_server'; then
            echo "$p"
        fi
    done
}

stop_server() {
    [[ -n "$IXSYS_PID" ]] || return 0
    local pids
    pids=$(descendants "$IXSYS_PID")

    log "停止 vLLM 进程树 (SIGTERM api_server,级联关闭 engine/worker)..."
    app_pids | xargs -r kill -TERM 2>/dev/null || true

    local i
    for (( i = 0; i < 30; i++ )); do
        [[ -z "$(app_pids)" ]] && break
        sleep 2
    done
    if [[ -n "$(app_pids)" ]]; then
        log "WARN: vLLM 未在 60s 内退出,强制 SIGKILL"
        app_pids | xargs -r kill -9 2>/dev/null || true
    fi
    # 兜底：启动时记录的后代里若还有残留（mp worker 可能被 init 收养），按 PID 清理。
    for p in $pids; do
        kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || true
    done

    # 等 ixsys 把 .tmp 转成 .ptrace 后退出（转换可能远超 60s，给 900s）。
    if kill -0 "$IXSYS_PID" 2>/dev/null; then
        log "vLLM 已退出,等待 ixsys 转换落盘 .ptrace (最多 900s)..."
        for (( i = 0; i < 450; i++ )); do
            kill -0 "$IXSYS_PID" 2>/dev/null || break
            sleep 2
        done
    fi
    if kill -0 "$IXSYS_PID" 2>/dev/null; then
        log "WARN: ixsys 900s 未退出,强制 kill -9 (trace 可能未完整落盘)"
        kill -9 "$IXSYS_PID" 2>/dev/null || true
    fi
    IXSYS_PID=""
    sleep 3
}

verify_trace() {
    local trace="$1"
    [[ -f "$trace" ]] || { log "ERROR: trace 不存在: $trace"; return 1; }
    local out kern api nvtx bounds
    out=$("$PYTHON_BIN" - "$trace" <<'PY' 2>/dev/null
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
def n(t):
    try:
        return db.execute("select count(*) from %s" % t).fetchone()[0]
    except Exception:
        return -1
try:
    bounds = db.execute("select count(*) from trace_bounds where end_ts > start_ts").fetchone()[0]
except Exception:
    bounds = -1
print(n("cuda_kernel_data"), n("cuda_api_data"), n("cuda_nvtx_data"), bounds)
PY
)
    read -r kern api nvtx bounds <<< "$out"
    log "trace 校验: cuda_kernel=${kern:-?} cuda_api=${api:-?} nvtx=${nvtx:-?} bounds_ok=${bounds:-?} ($(du -h "$trace" 2>/dev/null | cut -f1))"
    if [[ "${kern:-0}" -le 0 || "${bounds:-0}" -le 0 ]]; then
        log "ERROR: trace 不完整(无内核数据或无时间轴)，检查 ixsys 是否被提前 kill"
        return 1
    fi
    if [[ "${nvtx:-0}" -le 0 ]]; then
        log "提示: NVTX 为空，需要 IXSYS_TRACE=cuda,nvtx 才有 execute_context 注解"
    fi
    return 0
}

cleanup() {
    [[ "$CLEANED" == 1 ]] && return
    CLEANED=1
    if [[ -n "$BENCH_PID" ]]; then
        kill -TERM "$BENCH_PID" 2>/dev/null || true
        wait "$BENCH_PID" 2>/dev/null || true
        BENCH_PID=""
    fi
    stop_server
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
        kill -0 "$IXSYS_PID" 2>/dev/null || { log "ERROR: ixsys 已退出，查看 $SERVER_LOG"; return 1; }
        code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)
        [[ "$code" == 200 ]] && { log "服务就绪 (${elapsed}s)"; return 0; }
        sleep 5; elapsed=$((elapsed+5))
    done
    log 'ERROR: 服务启动超时'; return 1
}

start_server() {
    local trace="$1"
    "${CLEAN_ENV[@]}" "$PYTHON_BIN" - "$PORT" <<'PY' || return 1
import socket,sys
with socket.socket() as s:s.bind(('127.0.0.1',int(sys.argv[1])))
PY
    check_gpu_memory "$GPU_LIST"

    local -a ixsys_args app_cmd
    mapfile -t ixsys_args < <(build_ixsys_args "$trace")
    build_app_cmd app_cmd

    local -a outer_env=(CUDA_VISIBLE_DEVICES="$GPU_LIST" VLLM_ENFORCE_CUDA_GRAPH=1 VLLM_USE_V1=1
        "${SERVER_EXTRA_ENV[@]}")

    if [[ "$IXSYS_VERBOSE" == 1 ]]; then
        log "ixsys 命令: $IXSYS_BIN ${ixsys_args[*]} ${app_cmd[*]}"
    fi
    # 注意：ixsys 的应用命令不能用 "--" 分隔，且参数不能含空格（JSON 已压紧）。
    "${CLEAN_ENV[@]}" "${outer_env[@]}" "${SERVER_PREFIX[@]}" "$IXSYS_BIN" "${ixsys_args[@]}" \
        "${app_cmd[@]}" >> "$SERVER_LOG" 2>&1 &
    IXSYS_PID=$!
    log "ixsys PID=$IXSYS_PID；trace=$trace"
    wait_for_server
}

run_case() {
    local input_len="$1" output_len="$2"
    local case_id="bs${MAX_CONCURRENCY}_in${input_len}_out${output_len}"
    local case_log="${LOG_DIR}/bench_${case_id}.log"
    log "==== $case_id | mode=ixsys | warmup=$NUM_WARMUPS | 同一服务 ===="
    "${CLEAN_ENV[@]}" "$PYTHON_BIN" -m vllm.entrypoints.cli.main bench serve \
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
    log "完成 $case_id → ${RUN_DIR}/${case_id}.json"
}

# Validate cheap inputs before model initialization.
"${CLEAN_ENV[@]}" "$PYTHON_BIN" - "$GPU_LIST" "$NUM_PROMPTS" "$NUM_WARMUPS" "$MAX_CONCURRENCY" "$CASE_INTERVAL" "${CASES[@]}" <<'PY' || exit 2
import math,sys
ids,n,w,c,interval,*cases=sys.argv[1:]
if len(ids.split(','))!=4 or len(set(ids.split(',')))!=4:raise ValueError('需要四张不同 GPU')
if int(n)<=0 or int(w)<0 or int(c)<=0:raise ValueError('请求/预热/并发参数无效')
if float(interval)<0:raise ValueError('间隔无效')
if not cases or len(cases)!=len(set(cases)):raise ValueError('case 列表为空或重复')
for x in cases:
    parts=x.split()
    if len(parts)!=2 or min(map(int,parts))<=0 or sum(map(int,parts))>4096:raise ValueError('case 需要两个正整数且总长 <= 4096')
PY
log "TEST_ID=$TEST_ID | MODE=ixsys | WARMUP=$NUM_WARMUPS | CPU_RANGE=$CPU_RANGE"
log "prefix cache=OFF | backend=vllm | 同一服务运行 ${#CASES[@]} 个 case | RUN_DIR=$RUN_DIR"
log "ixsys trace=$TRACE_ROOT | IXSYS_TRACE=$IXSYS_TRACE (DEFER=$IXSYS_DEFER LIMIT=$IXSYS_LIMIT)"
if [[ "$HOST_DRY_RUN" == 1 ]]; then
    mapfile -t DRY_IXARGS < <(build_ixsys_args "$TRACE_ROOT/case.ptrace")
    build_app_cmd DRY_APP_CMD
    printf 'SERVER: '; printf '%q ' "${SERVER_PREFIX[@]}" "$IXSYS_BIN" "${DRY_IXARGS[@]}" "${DRY_APP_CMD[@]}"; printf '\n'
    printf 'CASES: '; printf '%s; ' "${CASES[@]}"; printf '\n'
    exit 0
fi
[[ -d "$MODEL_PATH" ]] || { log 'ERROR: MODEL_PATH 不是本地目录'; exit 2; }
if [[ -e "$RUN_DIR" ]]; then log 'ERROR: RUN_DIR 已存在，请换一个 TEST_ID，避免混入旧文件'; exit 2; fi
mkdir -p "$LOG_DIR" "$TRACE_ROOT"
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
    echo "host_path=$HOST_PATH mimalloc=$MIMALLOC"
    echo "host_opt=$HOST_OPT_TOTAL inputs=$HOST_OPT_INPUTS arena=$HOST_OPT_ARENA bookkeeping=$HOST_OPT_BOOKKEEPING positions=$HOST_OPT_POSITIONS metadata=$HOST_OPT_METADATA diagnostics=$HOST_OPT_DIAGNOSTICS"
    echo "compilation_config=$COMPILATION_CONFIG"
    echo "sampler=ixsys trace=$IXSYS_TRACE defer=$IXSYS_DEFER limit=$IXSYS_LIMIT"
} > "$RUN_DIR/config.txt" 2>/dev/null || true

FAILED=0
for idx in "${!CASES[@]}"; do
    read -r input_len output_len <<< "${CASES[$idx]}"
    case_id="bs${MAX_CONCURRENCY}_in${input_len}_out${output_len}"
    case_trace_dir="${TRACE_ROOT}/${case_id}"
    mkdir -p "$case_trace_dir"
    trace="${case_trace_dir}/${case_id}.ixsys.ptrace"

    if ! start_server "$trace"; then
        FAILED=1; log "ERROR: $case_id 启动失败"; break
    fi
    if ! run_case "$input_len" "$output_len"; then
        FAILED=1
    fi
    log "$case_id 完成，停服务让 ixsys 落盘 trace..."
    stop_server
    verify_trace "$trace" || FAILED=1
    if (( FAILED != 0 )); then
        log '停止后续 case，避免未完成请求或测量状态污染下一轮'; break
    fi
    if (( idx < ${#CASES[@]}-1 )); then log "等待 ${CASE_INTERVAL}s"; sleep "$CASE_INTERVAL"; fi
done

# 与 vllmBench 相同：用 lhctl 生成 summary.csv（不依赖 litehost 采集）。
if ! "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/lhctl.py" summary "$RUN_DIR" \
        > "$LOG_DIR/summary_build.log"; then
    FAILED=1
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

echo '===== ixsys Timeline 产物 ====='
find "$TRACE_ROOT" -type f 2>/dev/null | sort | head -50
log "全部完成 | benchmark=$SUMMARY_CSV | trace=$TRACE_ROOT"
