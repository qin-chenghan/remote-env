#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

IMAGE="${IMAGE:-local/vllm-metax:0.21.0-arm64-c500}"
GPUSEL="${GPUSEL:-7}"
MODEL_DIR="${MODEL_DIR:-/home/qch/models/Qwen3-0.6B}"
PROMPTS="${PROMPTS:-2000}"
WARMUPS="${WARMUPS:-16}"
CONCURRENCY="${CONCURRENCY:-2000}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-2000}"
IN_LEN="${IN_LEN:-128}"
OUT_LEN="${OUT_LEN:-128}"
MAX_LEN="${MAX_LEN:-4096}"
PORT_IN="${PORT_IN:-8000}"
PROFILE_TRACE="${PROFILE_TRACE:-1}"
TRACE_HOST="${TRACE_HOST:-/home/qch/qwen06_profile}"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### script: vllm-bench-31-v3（1024/1024 @ bs${CONCURRENCY}：bench + 离线 torch.profiler）"
  echo
  echo "### 本轮写入：起 --rm 临时容器跑 vLLM server + bench，再用离线 LLM 采 trace；GPU $GPUSEL；"
  echo "###           挂载 $MODEL_DIR（只读）和 $TRACE_HOST（trace 落盘）；"
  echo "###           不装包、不改系统配置、不留容器。"
  echo "### 配置：prompts=$PROMPTS warmups=$WARMUPS max_concurrency=$CONCURRENCY max_num_seqs=$MAX_NUM_SEQS"
  echo "### 说明：31 自身拉满口径（默认 240，2048-token 请求容量上限约 242）；118 仅用于和 32 对比"
  echo "### 预计：server 启动 ~4-6 分钟 + bench ~1-2 分钟 + 离线引擎再启动 ~4-6 分钟 + 生成 ~1-2 分钟"
  set +x

  echo
  echo "== 0. 前置检查（只读） =="
  date
  echo "-- 镜像 --"
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' 2>/dev/null | grep -F "$IMAGE" || {
      echo "!! 找不到镜像 $IMAGE"; exit 2; }
  echo "-- 模型 --"
  if [[ -f "$MODEL_DIR/config.json" && -f "$MODEL_DIR/model.safetensors" ]]; then
      ls -lh "$MODEL_DIR" | head -15
      echo "model_size=$(stat -c %s "$MODEL_DIR/model.safetensors")"
  else
      echo "!! 模型不完整：$MODEL_DIR"; exit 2
  fi
  echo "-- GPU 占用（共享卡预检） --"
  mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -20 || true
  if mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | grep -qiE 'python|vllm|ray|pt_main'; then
      echo "!! GPU 上有进程，按共享卡策略退出（等空闲再跑）"; exit 3
  fi
  mkdir -p "$TRACE_HOST"
  echo "trace_dir=$TRACE_HOST"

  echo
  echo "== 1. 容器内：vLLM server + bs$CONCURRENCY bench（写入：临时容器） =="
  docker run --rm -i --network=host --ipc=host --shm-size=16g \
      --device=/dev/mxcd \
      $(for d in /dev/dri/card* /dev/dri/renderD*; do [[ -e "$d" ]] && printf -- '--device=%s ' "$d"; done) \
      -e MACA_VISIBLE_DEVICES="$GPUSEL" -e CUDA_VISIBLE_DEVICES="$GPUSEL" \
      -e PROMPTS="$PROMPTS" -e WARMUPS="$WARMUPS" \
      -e CONCURRENCY="$CONCURRENCY" -e MAX_NUM_SEQS="$MAX_NUM_SEQS" \
      -e IN_LEN="$IN_LEN" -e OUT_LEN="$OUT_LEN" \
      -e MAX_LEN="$MAX_LEN" -e PORT_IN="$PORT_IN" \
      -e PROFILE_TRACE="$PROFILE_TRACE" \
      -v "$MODEL_DIR":/model:ro \
      -v "$TRACE_HOST":/profile \
      "$IMAGE" bash -s <<'INNER'
set -uo pipefail
echo "-- 容器内版本 --"
python3 - <<'PY'
import torch
import vllm
print("vllm", getattr(vllm, "__version__", "unknown"))
print("torch", torch.__version__)
print("device_count", torch.cuda.device_count())
p = torch.cuda.get_device_properties(0)
print("device", p.name, "sm", p.multi_processor_count, "mem_MB", round(p.total_memory/1024/1024))
PY

echo "-- server/bench CLI 探测 --"
python3 -m vllm.entrypoints.openai.api_server --help > /tmp/server_help.txt 2>&1 || true
EXTRA=()
grep -q -- '--async-scheduling' /tmp/server_help.txt && EXTRA+=(--async-scheduling)
grep -q -- '--compilation-config' /tmp/server_help.txt && EXTRA+=(--compilation-config '{}')
grep -q -- '--enable-chunked-prefill' /tmp/server_help.txt && EXTRA+=(--enable-chunked-prefill)
grep -q -- '--no-enable-prefix-caching' /tmp/server_help.txt && EXTRA+=(--no-enable-prefix-caching)
grep -q -- '--max-num-seqs' /tmp/server_help.txt && EXTRA+=(--max-num-seqs "$MAX_NUM_SEQS")
echo "server_extra=${EXTRA[*]:-none}"

if python3 -m vllm.entrypoints.cli.main bench serve --help > /tmp/bench_help.txt 2>&1; then
    BENCH=(python3 -m vllm.entrypoints.cli.main bench serve)
elif command -v vllm >/dev/null 2>&1 && vllm bench serve --help > /tmp/bench_help.txt 2>&1; then
    BENCH=(vllm bench serve)
else
    echo "!! 找不到 vllm bench serve"; tail -20 /tmp/bench_help.txt || true; exit 4
fi
echo "bench_cmd=${BENCH[*]}"

SRV_ARGS=(
    --host 127.0.0.1 --port "$PORT_IN" --model /model
    --trust-remote-code --dtype auto
    --max-model-len "$MAX_LEN" --tensor-parallel-size 1
    --gpu-memory-utilization 0.9
    "${EXTRA[@]}"
)
echo "-- 启动 server：${SRV_ARGS[*]} --"
python3 -m vllm.entrypoints.openai.api_server "${SRV_ARGS[@]}" > /tmp/server.log 2>&1 &
SPID=$!
cleanup() { kill "$SPID" 2>/dev/null || true; wait "$SPID" 2>/dev/null || true; }
trap cleanup EXIT

python3 - "$PORT_IN" <<'PY'
import sys, time, urllib.request
port = int(sys.argv[1])
t0 = time.time()
deadline = t0 + 1200
while time.time() < deadline:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as r:
            if r.status == 200:
                print("server healthy after %.1fs" % (time.time() - t0))
                sys.exit(0)
    except Exception:
        time.sleep(5)
print("server health timeout")
sys.exit(1)
PY
[[ $? -ne 0 ]] && { echo "!! server 未就绪"; tail -80 /tmp/server.log; exit 5; }

echo "-- KV 容量（server.log） --"
grep -m3 -E 'GPU KV cache size|kv cache size|KV cache size' /tmp/server.log || true

echo
echo "==== in${IN_LEN}/out${OUT_LEN} prompts=${PROMPTS} warmups=${WARMUPS} max_concurrency=${CONCURRENCY} max_num_seqs=${MAX_NUM_SEQS} ===="
timeout 2400 "${BENCH[@]}" \
    --backend vllm \
    --num_prompts "$PROMPTS" --num-warmups "$WARMUPS" --max-concurrency "$CONCURRENCY" \
    --dataset_name random --random_input_len "$IN_LEN" --random_output_len "$OUT_LEN" \
    --host 127.0.0.1 --port "$PORT_IN" --model /model --trust-remote-code \
    --ignore_eos --top_p 1 --top_k -1 --temperature 0 --seed 42 \
    --save-result --result-dir /tmp --result_filename "bs${CONCURRENCY}_in${IN_LEN}_out${OUT_LEN}.json" \
    > /tmp/bench_bs${CONCURRENCY}.log 2>&1
echo "bench_rc=$?"
tail -60 /tmp/bench_bs${CONCURRENCY}.log || true
echo "-- result json --"
cat "/tmp/bs${CONCURRENCY}_in${IN_LEN}_out${OUT_LEN}.json" 2>/dev/null || echo "(无结果文件)"

echo
echo "-- server 峰值 Running/Waiting/KV --"
grep -oE 'Running: [0-9]+ reqs, Waiting: [0-9]+ reqs, GPU KV cache usage: [0-9.]+%' /tmp/server.log \
  | awk '{r=$2; w=$5; k=$11; sub("%","",k); if (r>mr) mr=r; if (w>mw) mw=w; if (k>mk) mk=k; n++} END {printf "samples=%d  max_running=%d  max_waiting=%d  max_kv=%s%%\n", n, mr, mw, mk}'
echo "-- 峰值样本（Running 最大的一行） --"
grep -oE 'Running: [0-9]+ reqs, Waiting: [0-9]+ reqs, GPU KV cache usage: [0-9.]+%' /tmp/server.log \
  | sort -t' ' -k2 -n | tail -3
echo "-- server.log 尾部 --"
tail -10 /tmp/server.log || true
echo "-- 结束，杀 server --"
cleanup
trap - EXIT
echo "done"

if [[ "$PROFILE_TRACE" == "1" ]]; then
    echo
    echo "== 2. 离线 torch.profiler（bs$MAX_NUM_SEQS, in$IN_LEN/out$OUT_LEN，engine 同进程） =="
    VLLM_ENABLE_V1_MULTIPROCESSING=0 python3 - "$PROMPTS" "$IN_LEN" "$OUT_LEN" "$MAX_NUM_SEQS" <<'PY'
import dataclasses, os, random, sys, time, torch
from vllm import LLM, SamplingParams
from vllm.engine.arg_utils import EngineArgs

n, in_len, out_len, max_seqs = map(int, sys.argv[1:5])
fields = {f.name for f in dataclasses.fields(EngineArgs)}
wanted = {
    "model": "/model", "trust_remote_code": True, "dtype": "auto",
    "max_model_len": 4096, "tensor_parallel_size": 1,
    "gpu_memory_utilization": 0.9, "max_num_seqs": max_seqs,
    "enable_prefix_caching": False, "enable_chunked_prefill": True,
    "async_scheduling": True,
    "compilation_config": {"cudagraph_mode": "FULL_DECODE_ONLY", "mode": 0},
}
kwargs = {k: v for k, v in wanted.items() if k in fields}
print("LLM kwargs:", sorted(kwargs), flush=True)
llm = LLM(**kwargs)
rnd = random.Random(42)
prompts = [{"prompt_token_ids": [rnd.randrange(0, 1000) for _ in range(in_len)]} for _ in range(n)]
warm_sp = SamplingParams(temperature=0, top_p=1, top_k=-1, max_tokens=16, ignore_eos=True)
sp = SamplingParams(temperature=0, top_p=1, top_k=-1, max_tokens=out_len, ignore_eos=True)
t0 = time.time()
llm.generate(prompts[:16], warm_sp)
print("warmup %.1f s" % (time.time() - t0), flush=True)

prof = torch.profiler.profile(
    activities=[torch.profiler.ProfilerActivity.CPU, torch.profiler.ProfilerActivity.CUDA],
    record_shapes=False, profile_memory=False, with_stack=False)
t0 = time.time()
prof.__enter__()
llm.generate(prompts, sp)
prof.__exit__(None, None, None)
wall = time.time() - t0
avg = prof.key_averages()
tot = avg.total_average()
print("wall=%.2f s  self_cpu=%.3f s  self_cuda=%.3f s" % (
    wall, getattr(tot, "self_cpu_time_total", 0.0) / 1e6,
    getattr(tot, "self_cuda_time_total", 0.0) / 1e6))
print(avg.table(sort_by="self_cpu_time_total", row_limit=12))
print(avg.table(sort_by="self_cuda_time_total", row_limit=12))
path = "/profile/offline_bs%d_in%d_out%d.json" % (max_seqs, in_len, out_len)
prof.export_chrome_trace(path)
print("trace=%s %.1f MB" % (path, os.path.getsize(path) / 1048576))
PY
    echo "trace_phase_rc=$?"
fi
INNER
  echo "docker_rc=$?"

  echo
  echo "== 3. 结束后 GPU 状态（只读） =="
  mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -20 || true

  echo
  echo "### 完成：in${IN_LEN}/out${OUT_LEN} @ bs${CONCURRENCY}（bench + trace）"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
