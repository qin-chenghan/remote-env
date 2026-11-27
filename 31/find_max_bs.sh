#!/usr/bin/env bash
# 找 31 上 1024/1024 的最大并发：server 开 max_num_seqs=256，
# 按并发阶梯各跑一轮，观察 Running/Waiting/KV 与抢占。
# 用法：bash 31/find_max_bs.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

IMAGE="${IMAGE:-local/vllm-metax:0.21.0-arm64-c500}"
GPUSEL="${GPUSEL:-7}"
MODEL_DIR="${MODEL_DIR:-/home/qch/models/Qwen3-0.6B}"
SERVER_MAX_SEQS="${SERVER_MAX_SEQS:-256}"
CONC_LIST="${CONC_LIST:-180 220 240 245 248 250 252 256}"
WARMUPS="${WARMUPS:-8}"
IN_LEN="${IN_LEN:-1024}"
OUT_LEN="${OUT_LEN:-1024}"
MAX_LEN="${MAX_LEN:-4096}"
PORT_IN="${PORT_IN:-8000}"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### script: find-max-bs-31（1024/1024，server max_num_seqs=$SERVER_MAX_SEQS）"
  echo
  echo "### 本轮写入：起 --rm 临时容器跑 server + 多轮 bench；GPU $GPUSEL；"
  echo "###           不装包、不改系统配置、不留容器。"
  echo "### 阶梯：$CONC_LIST（每轮 prompts=并发，一波）"
  echo "### 预计：server 启动 ~4-6 分钟 + 每轮 ~30-40 秒"
  set +x

  echo
  echo "== 0. 前置检查（只读） =="
  date
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' 2>/dev/null | grep -F "$IMAGE" || {
      echo "!! 找不到镜像 $IMAGE"; exit 2; }
  if [[ -f "$MODEL_DIR/config.json" && -f "$MODEL_DIR/model.safetensors" ]]; then
      ls -lh "$MODEL_DIR" | head -6
  else
      echo "!! 模型不完整：$MODEL_DIR"; exit 2
  fi
  mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -20 || true
  if mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | grep -qiE 'python|vllm|ray|pt_main'; then
      echo "!! GPU 上有进程，按共享卡策略退出"; exit 3
  fi

  echo
  echo "== 1. 容器内：server + 并发阶梯 bench（写入：临时容器） =="
  docker run --rm -i --network=host --ipc=host --shm-size=16g \
      --device=/dev/mxcd \
      $(for d in /dev/dri/card* /dev/dri/renderD*; do [[ -e "$d" ]] && printf -- '--device=%s ' "$d"; done) \
      -e MACA_VISIBLE_DEVICES="$GPUSEL" -e CUDA_VISIBLE_DEVICES="$GPUSEL" \
      -e SERVER_MAX_SEQS="$SERVER_MAX_SEQS" -e CONC_LIST="$CONC_LIST" \
      -e WARMUPS="$WARMUPS" -e IN_LEN="$IN_LEN" -e OUT_LEN="$OUT_LEN" \
      -e MAX_LEN="$MAX_LEN" -e PORT_IN="$PORT_IN" \
      -v "$MODEL_DIR":/model:ro \
      "$IMAGE" bash -s <<'INNER'
set -uo pipefail

EXTRA=()
python3 -m vllm.entrypoints.openai.api_server --help > /tmp/server_help.txt 2>&1 || true
grep -q -- '--async-scheduling' /tmp/server_help.txt && EXTRA+=(--async-scheduling)
grep -q -- '--compilation-config' /tmp/server_help.txt && EXTRA+=(--compilation-config '{}')
grep -q -- '--enable-chunked-prefill' /tmp/server_help.txt && EXTRA+=(--enable-chunked-prefill)
grep -q -- '--no-enable-prefix-caching' /tmp/server_help.txt && EXTRA+=(--no-enable-prefix-caching)
grep -q -- '--max-num-seqs' /tmp/server_help.txt && EXTRA+=(--max-num-seqs "$SERVER_MAX_SEQS")

BENCH=(python3 -m vllm.entrypoints.cli.main bench serve)
python3 -m vllm.entrypoints.cli.main bench serve --help > /tmp/bench_help.txt 2>&1 || {
    echo "!! 找不到 vllm bench serve"; exit 4; }

echo "server_extra=${EXTRA[*]}"
echo "server_max_seqs=$SERVER_MAX_SEQS"

python3 -m vllm.entrypoints.openai.api_server \
    --host 127.0.0.1 --port "$PORT_IN" --model /model \
    --trust-remote-code --dtype auto \
    --max-model-len "$MAX_LEN" --tensor-parallel-size 1 \
    --gpu-memory-utilization 0.9 \
    "${EXTRA[@]}" > /tmp/server.log 2>&1 &
SPID=$!
cleanup() { kill "$SPID" 2>/dev/null || true; wait "$SPID" 2>/dev/null || true; }
trap cleanup EXIT

python3 - "$PORT_IN" <<'PY'
import sys, time, urllib.request
port = int(sys.argv[1])
t0 = time.time()
while time.time() < t0 + 1200:
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

KV=$(grep -m1 -oE 'GPU KV cache size: [0-9,]+' /tmp/server.log | tr -dc 0-9)
echo "gpu_kv_cache_tokens=$KV"
if [[ -n "$KV" ]]; then
    echo "expected_max_concurrency(2048 tokens/req)=$((KV / 2048))"
fi

for C in $CONC_LIST; do
    echo
    echo "==== C=$C prompts=$C max_concurrency=$C ===="
    before=$(wc -l < /tmp/server.log)
    timeout 1800 "${BENCH[@]}" \
        --backend vllm \
        --num_prompts "$C" --num-warmups "$WARMUPS" --max-concurrency "$C" \
        --dataset_name random --random_input_len "$IN_LEN" --random_output_len "$OUT_LEN" \
        --host 127.0.0.1 --port "$PORT_IN" --model /model --trust-remote-code \
        --ignore_eos --top_p 1 --top_k -1 --temperature 0 --seed 42 \
        --save-result --result-dir /tmp --result_filename "find_bs${C}.json" \
        > "/tmp/bench_bs${C}.log" 2>&1
    echo "bench_rc=$?"
    grep -E 'Successful requests|Failed requests|Benchmark duration|Request throughput|Output token throughput|Total token throughput|Median TTFT|Median TPOT|Median ITL' \
        "/tmp/bench_bs${C}.log" || tail -20 "/tmp/bench_bs${C}.log"
    cat "/tmp/find_bs${C}.json" 2>/dev/null || echo "(无结果文件)"
    echo "---- C=$C 服务端状态（本轮切片） ----"
    tail -n +"$((before + 1))" /tmp/server.log \
      | grep -oE 'Running: [0-9]+ reqs, Waiting: [0-9]+ reqs, GPU KV cache usage: [0-9.]+%' \
      | awk '{r=$2; w=$5; k=$11; sub("%","",k); if (r>mr) mr=r; if (w>mw) mw=w; if (k>mk) mk=k; n++} END {printf "samples=%d  max_running=%d  max_waiting=%d  max_kv=%s%%\n", n, mr, mw, mk}'
    echo "preempt_count=$(tail -n +"$((before + 1))" /tmp/server.log | grep -ci preempt || true)"
done

echo
echo "---- server.log 末尾 ----"
tail -10 /tmp/server.log || true
cleanup
trap - EXIT
echo "done"
INNER
  echo "docker_rc=$?"

  echo
  echo "== 2. 结束后 GPU 状态（只读） =="
  mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -20 || true

  echo
  echo "### 完成：并发阶梯 $CONC_LIST"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
