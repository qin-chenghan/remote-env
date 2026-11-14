#!/usr/bin/env bash
# =============================================================================
# timeline_opt.sh - vLLM timeline/profile 采集脚本(单实例版,全优化开关)
#
# 与原版的区别:所有能通过环境变量/编译配置打开的优化都写在脚本内部,
# 调用者不需要在 shell 里预先 export 任何东西(除了 MODEL_PATH / TEST_ID)。
#
# 部署: 天数容器vllm0.11.2 四卡单实例
# 用法:
#   export MODEL_PATH=/path/to/Qwen3-32B-W8A8
#   export TEST_ID=20260901_timeline
#   taskset -c 80-159,240-319 ./timeline_opt.sh
#
# 必传: MODEL_PATH, TEST_ID
# 可选: PYTHON_BIN / GPU_LIST / GPUS_PER_INSTANCE / PORT / NUM_PROMPTS /
#       NUM_WARMUPS / MAX_CONCURRENCY / ENABLE_TASKSET_BINDING / CPU_RANGE /
#       VLLM_RPC_TIMEOUT / PROFILE_EVERY
#
# 前置依赖(不满足会在启动前报错,不会跑到一半才崩):
#   - vllm 的 CompilationConfig 必须认识 compact_greedy / sample_logits_cudagraph_scope
#     (host-opt-pr-validation r14 及以上)
# =============================================================================

set -uo pipefail

# ============ 必传环境变量校验 ============
: "${MODEL_PATH:?ERROR: 必须设置 MODEL_PATH}"
: "${TEST_ID:?ERROR: 必须设置 TEST_ID}"

# ============ 优化开关(全部内联,不依赖调用者 shell)============
# 驱动侧:加大 UMD 命令缓冲,减少 ioctl 次数
export UMD_MAXCOMMANDBUFFERNUMBER="${UMD_MAXCOMMANDBUFFERNUMBER:-256}"
export UMD_MAXCOMMANDBUFFERSIZE="${UMD_MAXCOMMANDBUFFERSIZE:-16384}"

# torch:模块属性解析走 slot 原生 fastpath
export TORCH_MODULE_ATTR_FASTPATH="${TORCH_MODULE_ATTR_FASTPATH:-slot_native}"

# host 侧优化(host-opt-pr-validation r14)
#   子开关未设置时继承 VLLM_HOST_OPT;这里显式写出来,便于日后单独关掉某一项。
#   POSITIONS 额外要求 arena 打开且 context-parallel world size = 1。
export VLLM_HOST_OPT="${VLLM_HOST_OPT:-on}"
export VLLM_HOST_OPT_INPUTS="${VLLM_HOST_OPT_INPUTS:-on}"
export VLLM_HOST_OPT_ARENA="${VLLM_HOST_OPT_ARENA:-on}"
export VLLM_HOST_OPT_BOOKKEEPING="${VLLM_HOST_OPT_BOOKKEEPING:-on}"
export VLLM_HOST_OPT_POSITIONS="${VLLM_HOST_OPT_POSITIONS:-on}"
# diagnostics 是测量开销,不是优化项,保持关闭
export VLLM_HOST_OPT_DIAGNOSTICS="${VLLM_HOST_OPT_DIAGNOSTICS:-0}"
# 不要设置 VLLM_HOST_OPT_METADATA:r14 的 envs.py 未注册该变量,设了会在启动日志里
# 打 "Unknown vLLM environment variable";ilu_flash_attn.py 会回落到 VLLM_HOST_OPT。

# tcmalloc:降低 malloc 争用(server 与 bench 客户端都受益)
if [ -f /home/lw/gperftools/.libs/libtcmalloc.so ]; then
    export LD_PRELOAD="${LD_PRELOAD:-/home/lw/gperftools/.libs/libtcmalloc.so}"
    export TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES="${TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES:-536870912}"
fi

# ============ 可选环境变量(带默认值)============
PYTHON_BIN="${PYTHON_BIN:-python3}"
GPU_LIST="${GPU_LIST:-0,1,2,3}"
GPUS_PER_INSTANCE="${GPUS_PER_INSTANCE:-4}"
PORT="${PORT:-8000}"
NUM_PROMPTS="${NUM_PROMPTS:-100}"
NUM_WARMUPS="${NUM_WARMUPS:-16}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-8}"
ENABLE_TASKSET_BINDING="${ENABLE_TASKSET_BINDING:-0}"
CPU_RANGE="${CPU_RANGE:-}"
# profile flush 较慢,官方建议 30min
VLLM_RPC_TIMEOUT="${VLLM_RPC_TIMEOUT:-1800000}"
# PROFILE_EVERY=1 → 每个 case 都 profile
# PROFILE_EVERY=N → 每 N 个 case profile 一次(idx=0, N, 2N, ...)
PROFILE_EVERY="${PROFILE_EVERY:-1}"
# 每个 case 跑完后等待的间隔(秒),给 server / worker 资源释放时间
# profile case 间隔也要拉长,否则上一个 case 的 trace 还没 flush 完,影响下一个
CASE_INTERVAL="${CASE_INTERVAL:-60}"

# ============ 0.23 profiler schedule 参数 ============
# vLLM 0.23 完全弃用 VLLM_TORCH_PROFILER_DIR 环境变量,改用 --profiler-config。
# 关键点:warmup_iterations=0 时,vLLM 连续记录 /start_profile 到 /stop_profile
# 之间的 worker iteration;模型预热由 bench serve 在 /start_profile 前完成。
# warmup_iterations=0 时不启用一次性 schedule,由 stop_profile 结束并写出 trace。
#   delay_iterations: /start_profile 后跳过前 N 步再开始 profile(prefill 阶段或编译)
#   max_iterations  : profile 累计 N 步后自动 stop;0=不限,直到 /stop_profile
PROFILE_DELAY_ITERATIONS="${PROFILE_DELAY_ITERATIONS:-0}"
PROFILE_MAX_ITERATIONS="${PROFILE_MAX_ITERATIONS:-0}"
PROFILE_WARMUP_ITERATIONS="${PROFILE_WARMUP_ITERATIONS:-0}"
PROFILE_ACTIVE_ITERATIONS="${PROFILE_ACTIVE_ITERATIONS:-2000}"

# ============ 编译配置(全部开关打开)============
# compact_greedy:请求是纯 greedy(temperature=0/top_p=1/top_k=-1,本脚本的 bench 正是
#   这么发的)时跳过 top-p/top-k 归一化,直接 argmax。
# sample_logits_cudagraph:采样 logits 的切片/拷贝进图,避免每步 host 侧下发。
#   scope 取 vllm 默认值 decode,与 vllmBench_lite_opt.sh 的实际生效值一致;
#   显式写出是为了让 run_env.txt 能记录到,而不是依赖版本默认值。
COMPILATION_CONFIG='{"cudagraph_mode":"FULL_DECODE_ONLY", "mode":0, "compact_greedy":true, "sample_logits_cudagraph":true, "sample_logits_cudagraph_scope":"decode", "sample_logits_cudagraph_max_bytes":67108864, "sample_logits_cudagraph_capture_sizes":[1,2,3,4,5,6,7,8]}'

# ============ 目录结构 ============
BASE_DIR="$(pwd)"
RUN_DIR="${BASE_DIR}/timeline/${TEST_ID}"
LOG_DIR="${RUN_DIR}/logs"
PROFILE_ROOT_DIR="${PROFILE_ROOT_DIR:-${RUN_DIR}/profile}"
PROFILE_DIRS="${PROFILE_DIRS:-${PROFILE_ROOT_DIR}}"
SERVER_LOG="${LOG_DIR}/server.log"
SERVER_PID_FILE="${RUN_DIR}/server.pid"
mkdir -p "$LOG_DIR" "$PROFILE_DIRS"

# ============ 测试用例矩阵(跟 vllmBench.sh 一致,9 case)============
# 模型:   Qwen3-32B-W8A8
# 调度:   async
# bs:     8
# num:    32
# input:  {128, 1024, 2048}
# output: {128, 1024, 2048}
CASES=(
    "128 128"
#    "1024 2048"
#    "2048 1024"
#    "2048 2048"
)

# ============ 工具函数 ============

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# 解释器自检:venv 必须解析到自己的 torch/vllm。
# 容器全局 PYTHONPATH=/usr/local/lib/python3.12/site-packages 里是一棵残缺的 torch,
# 一旦被继承进来就排在 venv 之前,启动时报 "Failed to load PyTorch C extensions"。
# 两个 venv 的 bin/activate 末尾有 unset PYTHONPATH PYTHONHOME。
check_python_env() {
    "$PYTHON_BIN" - <<'PY'
import importlib.util, os, sys
bad = []
for name in ("torch", "vllm"):
    spec = importlib.util.find_spec(name)
    if spec is None or not (spec.origin or "").startswith(sys.prefix):
        bad.append("{} -> {}".format(name, spec.origin if spec else None))
if bad:
    print("解释器    :", sys.executable)
    print("prefix    :", sys.prefix)
    print("PYTHONPATH:", os.environ.get("PYTHONPATH"))
    for b in bad:
        print("  不在前缀下:", b)
    sys.exit(1)
PY
    if [ $? -ne 0 ]; then
        log "ERROR: PYTHON_BIN=$PYTHON_BIN 没有指向装好 vllm 的 venv"
        log "       先 source /opt/corex311-cpython-vllm/bin/activate(它会 unset PYTHONPATH)"
        return 1
    fi
    log "解释器自检通过: $("$PYTHON_BIN" -c 'import sys; print(sys.executable)')"
}

# 编译配置里的键是否被当前 vllm 的 CompilationConfig 认识。
# 不认识的话 server 会在加载配置时抛 TypeError,pydantic 报错堆栈很难读,
# 所以提前一秒判掉,不要浪费一次完整启动。
check_compilation_config_keys() {
    local site comp_file key missing=()
    site="$("$PYTHON_BIN" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null)"
    comp_file="${site}/vllm/config/compilation.py"
    if [ ! -f "$comp_file" ]; then
        log "WARN: 找不到 $comp_file,跳过编译配置键校验"
        return 0
    fi
    for key in compact_greedy sample_logits_cudagraph_scope; do
        grep -qE "^[[:space:]]*${key}:" "$comp_file" || missing+=("$key")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log "ERROR: ${comp_file} 里没有 ${missing[*]}"
        log "       当前 vllm 补丁代次早于 r14,不支持这套编译配置。"
        log "       要么升级补丁,要么从 COMPILATION_CONFIG 里去掉这些键。"
        return 1
    fi
    log "编译配置键校验通过($comp_file)"
}

should_profile_instance() {
    local idx="$1"
    [ $((idx % PROFILE_EVERY)) -eq 0 ]
}

wait_for_server() {
    local port="$1"
    local max_wait=600
    local elapsed=0

    while [ "$elapsed" -lt "$max_wait" ]; do
        if curl -s "http://127.0.0.1:${port}/health" > /dev/null 2>&1; then
            log "端口 $port 已就绪 (${elapsed}s)"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    log "ERROR: 端口 $port 超时未就绪!请查看 $SERVER_LOG"
    return 1
}

start_server() {
    log "启动 vLLM 服务 | model=$MODEL_PATH | gpu=$GPU_LIST | port=$PORT | python=$PYTHON_BIN"

    if [[ -f "$SERVER_PID_FILE" ]]; then
        log "检测到旧 server PID 文件，先停止旧进程"
        stop_server
    fi

    SERVER_PREFIX=()
    if [ "$ENABLE_TASKSET_BINDING" = "1" ]; then
        if [ -z "$CPU_RANGE" ]; then
            log "ERROR: ENABLE_TASKSET_BINDING=1 时必须设置 CPU_RANGE"
            return 1
        fi
        SERVER_PREFIX=(taskset -c "$CPU_RANGE")
        log "taskset 绑定: ${SERVER_PREFIX[*]}"
    fi

    # vLLM 0.23+ 完全弃用 VLLM_TORCH_PROFILER_DIR 环境变量,改用 --profiler-config。
    # 三个关键点:
    #  1. torch_profiler_dir 必须是绝对路径(0.23 内部 os.path.abspath 以 server 进程 cwd 为基准,
    #     相对路径可能解析不到 PROFILE_ROOT_DIR)
    #  2. ignore_frontend=true 避免前端 profiling 把整个 trace 范围录下来导致文件巨大
    #  3. warmup_iterations=0 时连续记录;模型 warmup 在 bench serve 中先执行
    local profile_dir_abs
    profile_dir_abs="$(cd "$(dirname "$PROFILE_DIRS")" 2>/dev/null && pwd)/$(basename "$PROFILE_DIRS")"

    local profiler_config_json
    profiler_config_json=$(cat <<EOF
{"profiler":"torch","torch_profiler_dir":"${profile_dir_abs}","delay_iterations":${PROFILE_DELAY_ITERATIONS},"max_iterations":${PROFILE_MAX_ITERATIONS},"warmup_iterations":${PROFILE_WARMUP_ITERATIONS},"active_iterations":${PROFILE_ACTIVE_ITERATIONS},"ignore_frontend":true}
EOF
)
    # 去掉 heredoc 引入的多余换行,确保是单行 JSON
    profiler_config_json="$(echo "$profiler_config_json" | tr -d '\n')"

    CUDA_VISIBLE_DEVICES="$GPU_LIST" \
    VLLM_ENFORCE_CUDA_GRAPH=1 \
    VLLM_USE_V1=1 \
    VLLM_RPC_TIMEOUT="$VLLM_RPC_TIMEOUT" \
    "${SERVER_PREFIX[@]}" "$PYTHON_BIN" -m vllm.entrypoints.openai.api_server \
        --host 127.0.0.1 \
        --port "$PORT" \
        --model "$MODEL_PATH" \
        --trust_remote_code \
        --dtype auto \
        --max_model_len 4096 \
        --distributed_executor_backend mp \
        --pipeline_parallel_size 1 \
        --tensor_parallel_size "$GPUS_PER_INSTANCE" \
        --data_parallel_size 1 \
        --quantization compressed-tensors \
        --gpu_memory_utilization 0.9 \
        --kv_cache_dtype auto \
        --enable_chunked_prefill \
        --compilation-config "$COMPILATION_CONFIG" \
        --async-scheduling \
        --no-enable-prefix-caching \
        --profiler-config "$profiler_config_json" \
        >> "$SERVER_LOG" 2>&1 &

    local pid=$!
    echo "$pid" > "$SERVER_PID_FILE"
    log "服务 PID: $pid, 日志: $SERVER_LOG, profile 目录(绝对): $profile_dir_abs"
    log "profiler-config: $profiler_config_json"

    wait_for_server "$PORT"

    # 校验 profiler 是否真的生效:从 server.log 里 grep 关键字
    #   - 'Profiler with mode' 来自 vllm/entrypoints/serve/profile/api_router.py
    #     表示 /start_profile /stop_profile 端点已注册
    #   - 'Torch profiling enabled' 来自 vllm/profiler/wrapper.py
    #     表示 worker 端 TorchProfilerWrapper 已配置
    # wait_for_server 之后 model_runner 已经初始化完毕,这两条 log 必然已写出
    if grep -qE "Profiler with mode|Torch profiling enabled" "$SERVER_LOG" 2>/dev/null; then
        log "✅ profiler 已生效(/start_profile /stop_profile 端点已注册,worker 端已配 TorchProfilerWrapper)"
    else
        log "❌ WARNING: server.log 里没找到 profiler 关键字"
        log "   请确认启动参数包含 --profiler-config '...profiler\\\":\\\"torch\\\"...' "
        log "   或在 server.log 里搜 'profiler' / 'profile' 看具体报错"
    fi
}

stop_server() {
    if [[ -f "$SERVER_PID_FILE" ]]; then
        local pid
        pid=$(cat "$SERVER_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "停止服务 (PID $pid) — profiler flush 可能要几分钟"
            kill "$pid" 2>/dev/null || true
            # 优雅等待最多 60s(profiler dump 可能慢)
            for _ in {1..30}; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    break
                fi
                sleep 2
            done
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$SERVER_PID_FILE"
    fi
    sleep 3
}

run_case() {
    local case_idx="$1"
    local input_len="$2"
    local output_len="$3"
    local bench_log="${LOG_DIR}/bench_instance${case_idx}.log"

    BENCH_PROFILE_ARGS=()
    if should_profile_instance "$case_idx"; then
        BENCH_PROFILE_ARGS=(--profile)
    fi

    local profile_state
    if [ ${#BENCH_PROFILE_ARGS[@]} -gt 0 ]; then
        profile_state="ON"
    else
        profile_state="OFF"
    fi
    log "==== case $case_idx: in=$input_len, out=$output_len (profile=$profile_state) ===="

    "$PYTHON_BIN" -m vllm.entrypoints.cli.main bench serve \
        --num_prompts "$NUM_PROMPTS" \
        --num_warmups "$NUM_WARMUPS" \
        --max-concurrency "$MAX_CONCURRENCY" \
        --dataset_name random \
        --random_input_len "$input_len" \
        --random_output_len "$output_len" \
        --host 127.0.0.1 \
        --port "$PORT" \
        --model "$MODEL_PATH" \
        --trust_remote_code \
        --ignore_eos \
        --top_p 1 \
        --top_k -1 \
        --temperature 0 \
        --seed 42 \
        "${BENCH_PROFILE_ARGS[@]}" \
        > "$bench_log" 2>&1

    return $?
}

cleanup() {
    # CLEANED 标志防重复执行(主流程显式调 + trap EXIT 兜底,可能触发两次)
    if [ "${CLEANED:-0}" -eq 0 ]; then
        CLEANED=1
        log "清理资源..."
        stop_server
    fi
}
trap cleanup EXIT

# ============ 主流程 ============

log "=========================================="
log "TEST_ID:           $TEST_ID"
log "MODEL_PATH:        $MODEL_PATH"
log "PYTHON_BIN:        $PYTHON_BIN"
log "GPU_LIST:          $GPU_LIST"
log "GPUS_PER_INSTANCE: $GPUS_PER_INSTANCE"
log "PORT:              $PORT"
log "NUM_PROMPTS:       $NUM_PROMPTS"
log "NUM_WARMUPS:       $NUM_WARMUPS (before profiler start)"
log "MAX_CONCURRENCY:   $MAX_CONCURRENCY"
log "TASKSET:            $ENABLE_TASKSET_BINDING ${CPU_RANGE:-}"
log "PROFILE_EVERY:     $PROFILE_EVERY (1=全 profile, 9=只 profile 第一个)"
log "VLLM_RPC_TIMEOUT:  $VLLM_RPC_TIMEOUT ms"
log "RUN_DIR:           $RUN_DIR"
log "PROFILE_DIRS:      $PROFILE_DIRS"
log "COMPILATION_CONFIG: $COMPILATION_CONFIG"
log "=========================================="
log "优化开关:"
log "  UMD_MAXCOMMANDBUFFERNUMBER=$UMD_MAXCOMMANDBUFFERNUMBER"
log "  UMD_MAXCOMMANDBUFFERSIZE=$UMD_MAXCOMMANDBUFFERSIZE"
log "  TORCH_MODULE_ATTR_FASTPATH=$TORCH_MODULE_ATTR_FASTPATH"
log "  VLLM_HOST_OPT=$VLLM_HOST_OPT"
log "  VLLM_HOST_OPT_INPUTS=$VLLM_HOST_OPT_INPUTS"
log "  VLLM_HOST_OPT_ARENA=$VLLM_HOST_OPT_ARENA"
log "  VLLM_HOST_OPT_BOOKKEEPING=$VLLM_HOST_OPT_BOOKKEEPING"
log "  VLLM_HOST_OPT_POSITIONS=$VLLM_HOST_OPT_POSITIONS"
log "  VLLM_HOST_OPT_DIAGNOSTICS=$VLLM_HOST_OPT_DIAGNOSTICS"
log "  LD_PRELOAD=${LD_PRELOAD:-}"
log "  TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES=${TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES:-}"
log "=========================================="
log "测试用例 ($((${#CASES[@]})) 个):"
for case_idx in "${!CASES[@]}"; do
    read -r input_len output_len <<< "${CASES[$case_idx]}"
    log "  case $case_idx: in=$input_len out=$output_len"
done

# 把这次实际生效的开关落盘,便于事后复现
{
    echo "# TEST_ID=$TEST_ID  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# uname: $(uname -srm)  PAGE_SIZE=$(getconf PAGE_SIZE)  boot=$(uptime -s 2>/dev/null)"
    echo "COMPILATION_CONFIG=$COMPILATION_CONFIG"
    env | grep -E '^(VLLM_|UMD_|TCMALLOC_|TORCH_MODULE|LD_PRELOAD)' | sort
} > "${RUN_DIR}/run_env.txt"

if ! check_python_env; then
    log "中止:解释器不对"
    exit 1
fi

if ! check_compilation_config_keys; then
    log "中止:编译配置与当前 vllm 不匹配"
    exit 1
fi

# 跑所有 case;每个 case 在自己的 profile 目录下启动 server。
# profiler 配置在 server 启动时固定，因此不同 case 必须分别启动 server。
FAILED_CASES=()
for idx in "${!CASES[@]}"; do
    read -r input_len output_len <<< "${CASES[$idx]}"

    # 每个 case 自己的 profile 子目录(在 PROFILE_ROOT_DIR 下再加一级)
    PROFILE_DIRS="${PROFILE_ROOT_DIR}/case${idx}_in${input_len}_out${output_len}"
    mkdir -p "$PROFILE_DIRS"

    # 第一个 case 直接启动，后续 case 停止旧 server 后再启动。
    if [[ -f "$SERVER_PID_FILE" ]]; then
        log "==== case $idx: 停旧 server,启新 server (PROFILE_DIRS=$PROFILE_DIRS) ===="
        stop_server
        # 给 vllm 完全释放资源的时间(stop_server 内部有 sleep 8+3,这里再加 CASE_INTERVAL 保险)
        log "等待 ${CASE_INTERVAL}s..."
        sleep "$CASE_INTERVAL"
    else
        log "==== case $idx: 启动 server (PROFILE_DIRS=$PROFILE_DIRS) ===="
    fi

    if ! start_server; then
        log "ERROR: case $idx 启动 server 失败"
        FAILED_CASES+=("in${input_len}_out${output_len}")
        continue
    fi

    if ! run_case "$idx" "$input_len" "$output_len"; then
        FAILED_CASES+=("in${input_len}_out${output_len}")
    fi
done

# 测试完成,显式调用 cleanup 清理 server(profile dump 也会被触发)
# trap EXIT 会兜底再调一次(CLEANED 标志保证不重复执行)
log "测试完成,调用 cleanup 清理资源..."
cleanup

# 列出 timeline 产物
echo ""
echo "===== Timeline 产物 ====="
find "$PROFILE_ROOT_DIR" -type f 2>/dev/null | head -50
echo ""
if [ ${#FAILED_CASES[@]} -gt 0 ]; then
    log "WARN: 以下 case 跑失败: ${FAILED_CASES[*]}"
fi
echo "全部完成。日志: $LOG_DIR"
echo "Timeline 目录(Perfetto JSON): $PROFILE_ROOT_DIR"
