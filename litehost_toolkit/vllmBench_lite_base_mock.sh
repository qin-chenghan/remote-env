#!/usr/bin/env bash
# Adapted from the uploaded vllmBench_lite.sh. Keep one server for all cases.
# Defaults retained: warmups=16, cache OFF, CPUs 192-255 (NUMA node 3), backend=vllm.
# Requires the matching files in this slim folder (included in the ZIP).
set -uo pipefail

MODEL_PATH="${MODEL_PATH:-/home/model/ts/Qwen3-32B-W8A8}"
TEST_ID="${TEST_ID:-"litehost_gap_$(date +%Y%m%d_%H%M%S)"}"
# JIT artifacts outlive /tmp cleanup and container restarts.
# 内核 .so 是 -march=native 编译的：重启后如果落到另一台物理机，复用旧 .so
# 会执行到本机不支持的指令（worker 被信号打死）。目录按 CPU 特征 + g++ 版本
# 分片：宿主不变零成本复用，宿主变了自动落新目录重新编译。
_host_tag() {
    { grep -m1 '^Features' /proc/cpuinfo 2>/dev/null
      { g++ -dumpfullversion -dumpversion 2>/dev/null || gcc --version 2>/dev/null | head -1; }
    } | md5sum | cut -c1-10
}
HOST_TAG="${HOST_TAG:-$(_host_tag)}"
TORCHINDUCTOR_CACHE_DIR="${TORCHINDUCTOR_CACHE_DIR:-/home/huawei_ts_program/inductor_cache_py311}"
[[ "$TORCHINDUCTOR_CACHE_DIR" == */h-* ]] || TORCHINDUCTOR_CACHE_DIR="$TORCHINDUCTOR_CACHE_DIR/h-$HOST_TAG"
export TORCHINDUCTOR_CACHE_DIR
mkdir -p "$TORCHINDUCTOR_CACHE_DIR" 2>/dev/null || true
PREFIX="${PREFIX:-/opt/corex311}"
PYTHON_BIN="${PYTHON_BIN:-${PREFIX}/bin/python3}"
GPU_LIST="${GPU_LIST:-0,1,2,3}"
GPUS_PER_INSTANCE="${GPUS_PER_INSTANCE:-4}"
PORT="${PORT:-8948}"  # mock 专用端口，避免与真实容器的 8848 冲突
NUM_PROMPTS="${NUM_PROMPTS:-100}"
NUM_WARMUPS="${NUM_WARMUPS:-16}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-8}"
CASE_INTERVAL="${CASE_INTERVAL:-60}"
CPU_RANGE="${CPU_RANGE-0-63}"
HOST_MEASURE="${HOST_MEASURE:-lite}"         # lite | off (never enable Torch Profiler here)
VLLM_RPC_TIMEOUT="${VLLM_RPC_TIMEOUT:-1800000}"
# 引擎初始化 RPC（含 graph capture/编译）的等待时间，vllm 默认 600 秒；
# 冷缓存编译可以超过 10 分钟，这里放宽到 30 分钟。注意它只影响父进程等多久，
# worker 被信号打死（SIGSEGV 等）是另一回事，调这个值救不回来。
VLLM_ENGINE_READY_TIMEOUT_S="${VLLM_ENGINE_READY_TIMEOUT_S:-1800}"
SERVER_WAIT_TIMEOUT="${SERVER_WAIT_TIMEOUT:-0}"   # 0 = 不设上限，直到服务就绪或进程退出
STALL_DUMP_SECONDS="${STALL_DUMP_SECONDS:-300}"   # graph capture 进度停滞多久自动抓栈；0=关闭
STALL_ABORT_SECONDS="${STALL_ABORT_SECONDS:-900}"  # 停滞多久放弃本轮（正常启动 3 分钟）；0=关闭
WARMUP_ONLY="${WARMUP_ONLY:-0}"                     # 1 = 只启动到就绪后停止，用于重启后预热编译
HOST_LINK_PERCENT="${HOST_LINK_PERCENT:-0}" # 5 means 5%, computed offline
HOST_TIMEOUT="${HOST_TIMEOUT:-120}"
HOST_MAX_SCOPES="${HOST_MAX_SCOPES:-200000}"
HOST_DRY_RUN="${HOST_DRY_RUN:-0}"
SERVER_EXTRA_ENV=(
    UMD_MAXCOMMANDBUFFERNUMBER=256
    UMD_MAXCOMMANDBUFFERSIZE=16384
)
# Pinned: both benchmark scripts always use the toolkit in this directory.
HOST_TOOLKIT=/home/huawei_ts_program/litehost_perf_opt
[[ -x "$PYTHON_BIN" && -f "$HOST_TOOLKIT/lhctl.py" ]] || { echo 'ERROR: Python 或配套文件缺失' >&2; exit 2; }
[[ "$HOST_MEASURE" == lite || "$HOST_MEASURE" == off ]] || { echo 'ERROR: HOST_MEASURE=lite|off' >&2; exit 2; }
[[ "$WARMUP_ONLY" == 0 || "$WARMUP_ONLY" == 1 ]] || { echo 'ERROR: WARMUP_ONLY=0|1' >&2; exit 2; }
[[ "$GPUS_PER_INSTANCE" == 4 ]] || { echo 'ERROR: 此版要求四卡 TP=4, PP=1, DP=1' >&2; exit 2; }
MOCK_DIR=/home/qch/mock_vllm
[[ -d "$MOCK_DIR/mock_gpu" ]] || { echo "ERROR: mock 目录不存在: $MOCK_DIR" >&2; exit 2; }
export PYTHONPATH="$MOCK_DIR${PYTHONPATH:+:$PYTHONPATH}"
# 启动保护默认开启，测试人员的命令行不用变：抓栈只注册信号、不影响测量。
# 绑核不进服务进程：准备阶段（导入/加载/capture）完全不绑，服务就绪后
# 由本脚本用 taskset -apc 给每个 worker 绑核（见 pin_workers_runtime）。
export MOCK_STACK_DUMP="${MOCK_STACK_DUMP:-1}"

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
log() {
    local line; line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$line"
    # 同时落盘：停滞保护/绑核这些判定只在这里出现，事后要能查
    if [[ -d "${LOG_DIR:-}" ]]; then printf '%s\n' "$line" >> "$LOG_DIR/harness.log"; fi
}
# Child processes only: drop old measurement/audit injection; keep CoreX library paths.
CLEAN_ENV=(env -u LD_PRELOAD -u LD_AUDIT -u LD_DEBUG -u LD_DEBUG_OUTPUT -u LD_BIND_NOT
    -u LD_PROFILE -u VLLM_TORCH_PROFILER_DIR -u PROFILER_CONFIG -u TORCH_PROFILER_DIR)

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
log "host_tag=$HOST_TAG inductor_cache=$TORCHINDUCTOR_CACHE_DIR files=$(find "$TORCHINDUCTOR_CACHE_DIR" -name '*.py' 2>/dev/null | wc -l)"

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
_capture_progress() {
    # tqdm 用 \r 刷新同一行，取最后一条 "Capturing CUDA graphs" 的 n/n
    tr '\r' '\n' < "$SERVER_LOG" 2>/dev/null \
        | grep -F 'Capturing CUDA graphs' | grep -oE '[0-9]+/[0-9]+' | tail -1
}
_last_phase() {
    local line
    line=$(grep -oE '\[[a-z_]+\.py:[0-9]+\] .*' "$SERVER_LOG" 2>/dev/null | tail -1)
    printf '%s' "${line:0:120}"
}
dump_stacks() {
    # SIGUSR2 只对已注册 handler 的 worker 安全；未注册时会直接杀掉进程。
    if ! grep -qF 'stack dump armed (SIGUSR2)' "$SERVER_LOG" 2>/dev/null; then
        log "WARNING: worker 未开始栈转储（需 MOCK_STACK_DUMP=1），跳过抓栈"
        return
    fi
    local -a pids=()
    command -v pgrep >/dev/null && mapfile -t pids < <(pgrep -f 'VLLM::Worker' 2>/dev/null)
    if (( ${#pids[@]} == 0 )); then
        local d cmd
        for d in /proc/[0-9]*; do
            cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
            [[ "$cmd" == *VLLM::* ]] && pids+=("${d#/proc/}")
        done
    fi
    if (( ${#pids[@]} == 0 )); then log "WARNING: 找不到 worker 进程，无法抓栈"; return; fi
    log "抓取线程栈 → $SERVER_LOG (pids: ${pids[*]})"
    kill -USR2 "${pids[@]}" 2>/dev/null || true
    sleep 3
}
wait_for_server() {
    # No fixed cap by default: graph capture on a cold JIT cache can take tens of minutes.
    # 但停滞会被单独盯住：抓栈（STALL_DUMP_SECONDS）和放弃（STALL_ABORT_SECONDS）。
    local elapsed=0 code prog prev="" stalled=0 last_dump=-1 phase
    while :; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log "ERROR: 服务已退出 (${elapsed}s)，最后 40 行日志："
            tail -n 40 "$SERVER_LOG" 2>/dev/null | sed 's/^/  | /'
            return 1
        fi
        code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)
        [[ "$code" == 200 ]] && { log "服务就绪 (${elapsed}s)"; return 0; }
        prog=$(_capture_progress)
        if [[ -n "$prog" ]]; then
            if [[ "$prog" == "$prev" ]]; then stalled=$((stalled+5))
            else stalled=0; prev="$prog"; last_dump=-1; fi
            if (( STALL_DUMP_SECONDS > 0 && stalled >= STALL_DUMP_SECONDS \
                  && (last_dump < 0 || stalled - last_dump >= STALL_DUMP_SECONDS) )); then
                log "WARNING: graph capture 停在 ${prog} 已 ${stalled}s，自动抓栈"
                dump_stacks; last_dump=$stalled
            fi
            if (( STALL_ABORT_SECONDS > 0 && stalled >= STALL_ABORT_SECONDS )); then
                log "ERROR: graph capture 停滞 ${stalled}s 无进展，放弃本轮（STALL_ABORT_SECONDS=${STALL_ABORT_SECONDS}）"
                return 1
            fi
        fi
        if (( SERVER_WAIT_TIMEOUT > 0 && elapsed >= SERVER_WAIT_TIMEOUT )); then
            log "ERROR: 服务启动超时 (${SERVER_WAIT_TIMEOUT}s)"; return 1
        fi
        if (( elapsed > 0 && elapsed % 300 == 0 )); then
            phase=$(_last_phase)
            log "等待服务中 (${elapsed}s) capture=${prog:-未开始}${phase:+ | 最近: $phase}"
        fi
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
    # MOCK_TP_CPUS 显式置空：服务进程一律不自行绑核（含 mock 的 DEFER 路径），
    # 绑核只发生在服务就绪之后，由 pin_workers_runtime 从外面用 taskset 施加。
    local -a env_args=(CUDA_VISIBLE_DEVICES="$GPU_LIST" VLLM_ENFORCE_CUDA_GRAPH=1 VLLM_USE_V1=1 \
        VLLM_RPC_TIMEOUT="$VLLM_RPC_TIMEOUT" VLLM_ENGINE_READY_TIMEOUT_S="$VLLM_ENGINE_READY_TIMEOUT_S"
        PYTHONFAULTHANDLER=1 MOCK_TP_CPUS= MOCK_TP_CPUS_DEFER=0
        "${SERVER_EXTRA_ENV[@]}")
    if [[ "$HOST_MEASURE" == lite ]]; then
        env_args+=(PYTHONPATH="${HOST_TOOLKIT}${PYTHONPATH:+:$PYTHONPATH}"
            LD_PRELOAD="$HOST_TOOLKIT/liblitehost.so"
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
    echo "host_tag=$HOST_TAG"
    echo "mock_env=MOCK_TP_CPUS=${MOCK_TP_CPUS:-unset}@runtime MOCK_STACK_DUMP=${MOCK_STACK_DUMP:-0} MOCK_THREADS=${MOCK_THREADS:-unset}"
    echo "stall_guard=STALL_DUMP_SECONDS=${STALL_DUMP_SECONDS} STALL_ABORT_SECONDS=${STALL_ABORT_SECONDS} SERVER_WAIT_TIMEOUT=${SERVER_WAIT_TIMEOUT} ENGINE_READY_TIMEOUT_S=${VLLM_ENGINE_READY_TIMEOUT_S}"
    echo "warmup_only=$WARMUP_ONLY"
} > "$RUN_DIR/config.txt" 2>/dev/null || true
# 预热与正常跑共用同一套初始化：LightHostWorker 会读 lhctl 生成的 session.json
if [[ "$HOST_MEASURE" == lite ]]; then
    "${CLEAN_ENV[@]}" "$PYTHON_BIN" "$HOST_TOOLKIT/lhctl.py" init --run-dir "$RUN_DIR" \
        --timeout "$HOST_TIMEOUT" --max-scopes "$HOST_MAX_SCOPES" > "$LOG_DIR/preflight.log" 2>&1 || { cat "$LOG_DIR/preflight.log"; exit 2; }
    INIT_DONE=1
fi
PCH_DIR=/tmp/torchinductor_root/precompiled_headers
_pch_count() { ls -1 "$PCH_DIR"/*.h 2>/dev/null | wc -l; }
_so_count() { find "$TORCHINDUCTOR_CACHE_DIR" -name '*.so' 2>/dev/null | wc -l; }
preflight_import() {
    # 启动前量一次 import vllm：机器异常慢时（见过单进程 3m45）与其等一小时
    # 才发现，不如在这里先看到耗时；顺带把解释器和库预热进页缓存。
    local t0 t1 rc
    t0=$(date +%s)
    "${CLEAN_ENV[@]}" timeout "${PREFLIGHT_IMPORT_TIMEOUT:-600}" \
        env PYTHONPATH="$MOCK_DIR" MOCK_TP_CPUS= \
        "$PYTHON_BIN" -c 'import vllm' >> "$LOG_DIR/preflight.log" 2>&1
    rc=$?
    t1=$(date +%s)
    if (( rc == 124 )); then
        log "ERROR: 预检 import vllm 超过 ${PREFLIGHT_IMPORT_TIMEOUT:-600}s，机器状态异常，放弃本轮"
        return 1
    elif (( rc != 0 )); then
        log "ERROR: 预检 import vllm 失败 (rc=$rc)，详见 $LOG_DIR/preflight.log"
        return 1
    fi
    log "预检：import vllm 用时 $((t1-t0))s"
    (( t1-t0 <= 60 )) || log "WARNING: import vllm 明显偏慢（正常 <15s），本机当前状态不佳"
    return 0
}
PCH_BEFORE=$(_pch_count); SO_BEFORE=$(_so_count)
preflight_import || exit 1
if ! start_server; then log 'FATAL: 启动失败'; exit 1; fi
# 回读 /proc/<pid>/status 的 Cpus_allowed_list，证明绑核真的生效了（而不是静默跳过）。
_affinity_audit() {
    local p out=''
    for p in $(pgrep -f 'VLLM::Worker' 2>/dev/null); do
        out+=" $p=$(awk '/Cpus_allowed_list/{print $2}' "/proc/$p/status" 2>/dev/null)"
    done
    log "$1（Cpus_allowed_list）:${out:- 未找到 worker 进程}"
}
_affinity_audit "准备阶段绑核状态（应未绑核）"

_worker_pid() {
    # rank -> pid：优先用 litehost 就绪文件，off 模式退回解析 server.log
    local f="$RUN_DIR/control/rank$1.ready.json" pid=''
    [[ -r "$f" ]] && pid=$(grep -oE '"pid": *[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    if [[ -z "$pid" ]]; then
        pid=$(grep -m1 -E "\(Worker pid=[0-9]+\) .*[[:space:]]rank=$1[[:space:]]" "$SERVER_LOG" 2>/dev/null \
              | grep -oE 'Worker pid=[0-9]+' | cut -d= -f2)
    fi
    printf '%s' "$pid"
}
pin_workers_runtime() {
    # 运行期绑核：服务已就绪，准备工作（导入/权重/编译/capture）全部结束，
    # 此时再绑不影响测量口径，也不再拖慢任何启动步骤。
    [[ -n "${MOCK_TP_CPUS:-}" ]] || { log '绑核：MOCK_TP_CPUS 未设置，跳过'; return 0; }
    command -v taskset >/dev/null || { log '绑核：容器内没有 taskset'; return 1; }
    local -a cpus; IFS=',' read -ra cpus <<< "$MOCK_TP_CPUS"
    local i pid ok=0 fail=0
    for i in "${!cpus[@]}"; do
        pid=$(_worker_pid "$i")
        if [[ -z "$pid" ]]; then log "绑核：找不到 rank $i 的 pid"; fail=$((fail+1)); continue; fi
        if taskset -apc "${cpus[$i]}" "$pid" >/dev/null 2>&1; then
            log "绑核：rank $i pid=$pid -> cpu ${cpus[$i]}"; ok=$((ok+1))
        else
            log "绑核：rank $i pid=$pid -> cpu ${cpus[$i]} 失败"; fail=$((fail+1))
        fi
    done
    log "绑核完成：成功 $ok 个，失败 $fail 个"
    (( fail == 0 ))
}
if [[ "$WARMUP_ONLY" == 1 ]]; then
    # 预热不改动测量口径：编译已全部落在启动阶段，这里只是提前付掉
    log "预热完成：PCH 新增 $(( $(_pch_count) - PCH_BEFORE )) 个，内核 .so 新增 $(( $(_so_count) - SO_BEFORE )) 个"
    log '服务已停止；现在按正常命令跑测量即可，不会再触发编译'
    exit 0
fi
if ! pin_workers_runtime; then log 'FATAL: 运行期绑核失败，放弃本轮（不产出未绑核的数据）'; exit 1; fi
_affinity_audit "运行阶段绑核状态"
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
