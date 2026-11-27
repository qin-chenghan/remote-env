#!/usr/bin/env bash
# 31 上采 128/128 的 torch profiler timeline：
# 离线 LLM.generate（单进程，VLLM_ENABLE_V1_MULTIPROCESSING=0）+ profile 包住生成，
# 导出 Perfetto json 后原地解析 GPU/CPU 时间占比。
# 用法：bash 31/timeline128.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

IMAGE="${IMAGE:-local/vllm-metax:0.21.0-arm64-c500}"
GPUSEL="${GPUSEL:-7}"
MODEL_DIR="${MODEL_DIR:-/home/qch/models/Qwen3-0.6B}"
PROMPTS="${PROMPTS:-100}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
WARMUPS="${WARMUPS:-16}"
IN_LEN="${IN_LEN:-128}"
OUT_LEN="${OUT_LEN:-128}"
MAX_LEN="${MAX_LEN:-4096}"
TRACE_HOST="${TRACE_HOST:-/home/qch/qwen06_profile}"
TRACE_NAME="${TRACE_NAME:-offline_bs${MAX_NUM_SEQS}_in${IN_LEN}_out${OUT_LEN}.json}"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### script: timeline-31（in${IN_LEN}/out${OUT_LEN}，prompts=${PROMPTS}，并发=${MAX_NUM_SEQS}，torch.profiler）"
  echo
  echo "### 本轮写入：起 --rm 临时容器跑离线 LLM，trace 落 $TRACE_HOST；"
  echo "###           不装包、不起 server、不改系统配置、不留容器。"
  echo "### 口径：与 32 的 1125 timeline 对齐（100 prompts、并发 8、16 warmup），TP1。"
  echo "### 预计：engine 启动 ~4-6 分钟 + 生成 ~10-20 秒 + 解析 <1 分钟"
  set +x

  echo
  echo "== 0. 前置检查（只读） =="
  date
  echo "-- 镜像 --"
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' 2>/dev/null | grep -F "$IMAGE" || {
      echo "!! 找不到镜像 $IMAGE"; exit 2; }
  echo "-- 模型 --"
  if [[ -f "$MODEL_DIR/config.json" && -f "$MODEL_DIR/model.safetensors" ]]; then
      ls -lh "$MODEL_DIR" | head -6
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
  df -h /home | tail -1
  free -g | head -3

  echo
  echo "== 1. 容器内：离线 LLM + torch.profiler（写入：临时容器 + trace） =="
  docker run --rm -i --network=host --ipc=host --shm-size=16g \
      --device=/dev/mxcd \
      $(for d in /dev/dri/card* /dev/dri/renderD*; do [[ -e "$d" ]] && printf -- '--device=%s ' "$d"; done) \
      -e MACA_VISIBLE_DEVICES="$GPUSEL" -e CUDA_VISIBLE_DEVICES="$GPUSEL" \
      -e PROMPTS="$PROMPTS" -e MAX_NUM_SEQS="$MAX_NUM_SEQS" -e WARMUPS="$WARMUPS" \
      -e IN_LEN="$IN_LEN" -e OUT_LEN="$OUT_LEN" -e MAX_LEN="$MAX_LEN" \
      -e TRACE_NAME="$TRACE_NAME" \
      -v "$MODEL_DIR":/model:ro \
      -v "$TRACE_HOST":/profile \
      -v "$DIR":/scripts:ro \
      "$IMAGE" bash -s <<'INNER'
set -uo pipefail
echo "-- 容器内版本 --"
python3 - <<'PY'
import torch, vllm
print("vllm", getattr(vllm, "__version__", "unknown"))
print("torch", torch.__version__)
print("device_count", torch.cuda.device_count())
p = torch.cuda.get_device_properties(0)
print("device", p.name, "sm", p.multi_processor_count, "mem_MB", round(p.total_memory/1024/1024))
PY

export VLLM_ENABLE_V1_MULTIPROCESSING=0
python3 <<'PY'
import dataclasses, os, random, sys, time, torch
from vllm import LLM, SamplingParams
from vllm.engine.arg_utils import EngineArgs

n = int(os.environ["PROMPTS"])
max_seqs = int(os.environ["MAX_NUM_SEQS"])
warmups = int(os.environ["WARMUPS"])
in_len = int(os.environ["IN_LEN"])
out_len = int(os.environ["OUT_LEN"])
max_len = int(os.environ["MAX_LEN"])
trace_name = os.environ["TRACE_NAME"]

fields = {f.name for f in dataclasses.fields(EngineArgs)}
wanted = {
    "model": "/model", "trust_remote_code": True, "dtype": "auto",
    "max_model_len": max_len, "tensor_parallel_size": 1,
    "gpu_memory_utilization": 0.9, "max_num_seqs": max_seqs,
    "enable_prefix_caching": False, "enable_chunked_prefill": True,
    "async_scheduling": True,
    "compilation_config": {"cudagraph_mode": "FULL_DECODE_ONLY", "mode": 0},
}
kwargs = {k: v for k, v in wanted.items() if k in fields}
print("LLM kwargs:", sorted(kwargs), flush=True)
t0 = time.time()
llm = LLM(**kwargs)
print("engine ready %.1f s" % (time.time() - t0), flush=True)

rnd = random.Random(42)
prompts = [{"prompt_token_ids": [rnd.randrange(0, 1000) for _ in range(in_len)]} for _ in range(n)]
warm_sp = SamplingParams(temperature=0, top_p=1, top_k=-1, max_tokens=16, ignore_eos=True)
sp = SamplingParams(temperature=0, top_p=1, top_k=-1, max_tokens=out_len, ignore_eos=True)
w = min(warmups, n)
t0 = time.time()
llm.generate(prompts[:w], warm_sp)
print("warmup(%d) %.1f s" % (w, time.time() - t0), flush=True)

prof = torch.profiler.profile(
    activities=[torch.profiler.ProfilerActivity.CPU, torch.profiler.ProfilerActivity.CUDA],
    record_shapes=False, profile_memory=False, with_stack=False)
t0 = time.time()
prof.__enter__()
outs = llm.generate(prompts, sp)
prof.__exit__(None, None, None)
wall = time.time() - t0
gen_tokens = sum(len(o.outputs[0].token_ids) for o in outs)
print("wall=%.2f s  requests=%d  gen_tokens=%d  (%.1f tok/s)" % (
    wall, len(outs), gen_tokens, gen_tokens / wall if wall else 0.0))
avg = prof.key_averages()
tot = avg.total_average()
print("self_cpu=%.3f s  self_cuda=%.3f s" % (
    getattr(tot, "self_cpu_time_total", 0.0) / 1e6,
    getattr(tot, "self_cuda_time_total", 0.0) / 1e6))
print(avg.table(sort_by="self_cpu_time_total", row_limit=10))
print(avg.table(sort_by="self_cuda_time_total", row_limit=10))
path = "/profile/" + trace_name
prof.export_chrome_trace(path)
print("trace=%s %.1f MB" % (path, os.path.getsize(path) / 1048576))
PY
echo "trace_phase_rc=$?"

echo
echo "-- 原地解析 GPU/CPU 占比 --"
python3 /scripts/parse_trace.py "/profile/$TRACE_NAME"
echo "parse_rc=$?"
INNER
  echo "docker_rc=$?"

  echo
  echo "== 2. 结束后 GPU 状态（只读） =="
  mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -20 || true

  echo
  echo "### 完成：in${IN_LEN}/out${OUT_LEN} timeline（$TRACE_HOST/$TRACE_NAME）"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
