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
PROMPTS="${PROMPTS:-100}"
WARMUPS="${WARMUPS:-16}"
CONCURRENCY_LIST="${CONCURRENCY_LIST:-8 100}"
IN_LEN="${IN_LEN:-1024}"
OUT_LEN="${OUT_LEN:-1024}"
MAX_LEN="${MAX_LEN:-4096}"
PORT_IN="${PORT_IN:-8000}"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### script: vllm-bench-31-v1（容器内起 vLLM，vllm bench serve 直接出 TTFT/TPOT/ITL/吞吐）"
  echo
  echo "### 本轮写入：启动 --rm 临时容器跑 vLLM 服务 + bench；GPU $GPUSEL；"
  echo "###           挂载 $MODEL_DIR（只读）；结果 JSON 留在容器 /tmp 并打印到日志；"
  echo "###           不装包、不改配置、不留容器。预计 5-15 分钟（首次启动可能编译）。"
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
  echo "-- GPU 占用 --"
  mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -20 || true
  if mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | grep -qiE 'python|vllm|ray|pt_main'; then
      echo "!! GPU 上有进程，按共享卡策略退出"; exit 3
  fi

  echo
  echo "== 1. 容器内：vLLM server + bench（写入：临时容器） =="
  docker run --rm -i --network=host --ipc=host --shm-size=16g \
      --device=/dev/mxcd \
      $(for d in /dev/dri/card* /dev/dri/renderD*; do [[ -e "$d" ]] && printf -- '--device=%s ' "$d"; done) \
      -e MACA_VISIBLE_DEVICES="$GPUSEL" -e CUDA_VISIBLE_DEVICES="$GPUSEL" \
      -e PROMPTS="$PROMPTS" -e WARMUPS="$WARMUPS" \
      -e CONCURRENCY_LIST="$CONCURRENCY_LIST" \
      -e IN_LEN="$IN_LEN" -e OUT_LEN="$OUT_LEN" \
      -e MAX_LEN="$MAX_LEN" -e PORT_IN="$PORT_IN" \
      -v "$MODEL_DIR":/model:ro \
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
SERVER=(python3 -m vllm.entrypoints.openai.api_server)
python3 -m vllm.entrypoints.openai.api_server --help > /tmp/server_help.txt 2>&1 || true
EXTRA=()
grep -q -- '--async-scheduling' /tmp/server_help.txt && EXTRA+=(--async-scheduling)
grep -q -- '--compilation-config' /tmp/server_help.txt && EXTRA+=(--compilation-config '{}')
grep -q -- '--enable-chunked-prefill' /tmp/server_help.txt && EXTRA+=(--enable-chunked-prefill)
grep -q -- '--no-enable-prefix-caching' /tmp/server_help.txt && EXTRA+=(--no-enable-prefix-caching)
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
import json, sys, time, urllib.request
port = int(sys.argv[1])
deadline = time.time() + 600
while time.time() < deadline:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as r:
            if r.status == 200:
                print("server healthy after %.1fs" % (600 - (deadline - time.time())))
                sys.exit(0)
    except Exception:
        time.sleep(5)
print("server health timeout")
sys.exit(1)
PY
[[ $? -ne 0 ]] && { echo "!! server 未就绪"; tail -60 /tmp/server.log; exit 5; }

for BS in $CONCURRENCY_LIST; do
    echo
    echo "==== in${IN_LEN}/out${OUT_LEN} prompts=${PROMPTS} warmups=${WARMUPS} bs=${BS} ===="
    timeout 900 "${BENCH[@]}" \
        --backend vllm \
        --num_prompts "$PROMPTS" --num-warmups "$WARMUPS" --max-concurrency "$BS" \
        --dataset_name random --random_input_len "$IN_LEN" --random_output_len "$OUT_LEN" \
        --host 127.0.0.1 --port "$PORT_IN" --model /model --trust-remote-code \
        --ignore_eos --top_p 1 --top_k -1 --temperature 0 --seed 42 \
        --save-result --result-dir /tmp --result_filename "bs${BS}_in${IN_LEN}_out${OUT_LEN}.json" \
        > /tmp/bench_bs${BS}.log 2>&1
    echo "bench_rc=$?"
    tail -40 /tmp/bench_bs${BS}.log || true
    echo "-- result json --"
    cat "/tmp/bs${BS}_in${IN_LEN}_out${OUT_LEN}.json" 2>/dev/null || echo "(无结果文件)"
    echo
done

echo "-- server.log 尾部 --"
tail -30 /tmp/server.log || true
echo "-- 结束，杀 server --"
cleanup
trap - EXIT
echo "done"
INNER
  echo "docker_rc=$?"

  echo
  echo "== 2. 结束后 GPU 状态（只读） =="
  mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -20 || true

  echo
  echo "### 完成：in${IN_LEN}/out${OUT_LEN}，bs=${CONCURRENCY_LIST}"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
