#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

REF_CTN="${REF_CTN:-corex5-py311}"
MODEL_CTN_PATH="${MODEL_CTN_PATH:-/home/model/ts/Qwen3-0.6B}"
GPUSEL="${GPUSEL:-7}"
CPU_RANGE="${CPU_RANGE:-192-255}"
PROMPTS="${PROMPTS:-100}"
WARMUPS="${WARMUPS:-16}"
CONCURRENCY_LIST="${CONCURRENCY_LIST:-8 100}"
IN_LEN="${IN_LEN:-1024}"
OUT_LEN="${OUT_LEN:-1024}"
MAX_LEN="${MAX_LEN:-4096}"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### script: vllm-bench-32-clean-v1（不带 litehost / 不用旧容器 overlay，全新 --rm 容器）"
  echo
  echo "### 本轮写入：1) 备份 qwen06_lite_9c_1127 原始 9-case 数据；"
  echo "###           2) 删除旧的 qwen3-0.6b-benchmark.tar.gz（后续重打）；"
  echo "###           3) 用 $REF_CTN 同镜像起 --rm 容器，GPU $GPUSEL，跑 1024/1024 bs=$CONCURRENCY_LIST；"
  echo "###           不装包、不改系统、不改 base 结果目录。预计 5-15 分钟。"
  set +x

  echo
  echo "== 0. 前置检查（只读） =="
  uname -m; nproc
  df -BG /home | tail -1
  echo "-- 参考容器 --"
  docker ps --format '{{.Names}}' | grep -qx "$REF_CTN" && echo "$REF_CTN 在" || { echo "!! $REF_CTN 不在"; exit 10; }
  IMAGE=$(docker inspect "$REF_CTN" --format '{{.Config.Image}}')
  PRIV=$(docker inspect "$REF_CTN" --format '{{.HostConfig.Privileged}}')
  echo "image=$IMAGE privileged=$PRIV ipc=$(docker inspect "$REF_CTN" --format '{{.HostConfig.IpcMode}}') runtime=$(docker inspect "$REF_CTN" --format '{{.HostConfig.Runtime}}') shm=$(docker inspect "$REF_CTN" --format '{{.HostConfig.ShmSize}}')"
  echo "-- 参考容器的 devices --"
  docker inspect "$REF_CTN" --format '{{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}' | tr ' ' '\n' | sed '/^$/d'
  echo "-- 参考容器的 binds --"
  docker inspect "$REF_CTN" --format '{{range .HostConfig.Binds}}{{.}} {{end}}' | tr ' ' '\n' | sed '/^$/d' | head -20

  echo "-- 模型路径 --"
  if [[ -f "/home/model/ts/Qwen3-0.6B/config.json" ]]; then
      MODEL_HOST="$MODEL_CTN_PATH"
      echo "宿主机直接可见：$MODEL_HOST"
  else
      echo "宿主机不可见，尝试从 $REF_CTN 的 mount 反推宿主机路径"
      MODEL_HOST=$(docker inspect "$REF_CTN" --format '{{json .Mounts}}' | \
          docker exec -i "$REF_CTN" python3 -c '
import json, sys
mounts = json.load(sys.stdin)
cp = sys.argv[1].rstrip("/")
best = None
for m in mounts:
    d = m.get("Destination", "").rstrip("/")
    if cp == d or cp.startswith(d + "/"):
        if best is None or len(d) > len(best["Destination"].rstrip("/")):
            best = m
if best:
    d = best["Destination"].rstrip("/")
    print(best["Source"].rstrip("/") + cp[len(d):])
' "$MODEL_CTN_PATH")
      echo "反推结果：${MODEL_HOST:-（失败）}"
  fi
  [[ -n "${MODEL_HOST:-}" && -f "$MODEL_HOST/config.json" ]] || { echo "!! 找不到模型 $MODEL_CTN_PATH"; exit 11; }
  ls -lh "$MODEL_HOST" | head -12

  echo "-- GPU 占用（共享机） --"
  IXSMI="$(command -v ixsmi || echo /usr/local/corex/bin/ixsmi)"
  [[ -x "$IXSMI" ]] || { echo "!! 找不到 ixsmi"; exit 12; }
  "$IXSMI" --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -12 || true
  used=$("$IXSMI" --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null | awk -F', *' -v g="$GPUSEL" '$1==g{print $2}')
  echo "gpu${GPUSEL}_used_MiB=${used:-unknown}"
  if [[ -n "${used:-}" && "$used" -gt 2048 ]]; then echo "!! GPU $GPUSEL 已用 ${used} MiB，退出"; exit 13; fi

  echo
  echo "== 1. 备份 9-case 原始数据 + 定位正式文档（写入：只新增备份） =="
  SRC=/home/qch/scripts/litehost_perf/vllmBench/qwen06_lite_9c_1127
  BK="${SRC}.bak-$(date +%Y%m%d)"
  if [[ -d "$SRC" ]]; then
      du -sh "$SRC"
      if [[ -e "$BK" ]]; then
          echo "备份已存在：$BK"
      else
          cp -a "$SRC" "$BK" && echo "已备份 -> $BK"
      fi
      echo "-- 原始 summary.csv（只读） --"
      head -12 "$SRC/summary.csv" 2>/dev/null || true
  else
      echo "!! 找不到 $SRC"
  fi
  echo "-- 候选正式文档 --"
  find /home/qch -maxdepth 6 -name '数据统计.md' -path '*qwen3-0.6B*' 2>/dev/null | head -5
  find /home/qch -maxdepth 5 -type d -name analysis 2>/dev/null | head -5
  echo "-- 文档中 1024/1024 相关行（只读） --"
  while IFS= read -r d; do
      grep -rn --include='*.md' -E 'in.?1024.*out.?1024|1024 ?/ ?1024|1024 1024' "$d" 2>/dev/null | head -10 || true
  done < <(find /home/qch -maxdepth 5 -type d -name analysis 2>/dev/null | head -3)

  echo
  echo "== 2. 删除旧压缩包（写入） =="
  rm -fv /home/qch/qwen06_export/qwen3-0.6b-benchmark.tar.gz 2>/dev/null || echo "旧包不存在或已删"
  ls -la /home/qch/qwen06_export 2>/dev/null || true

  echo
  echo "== 3. 全新容器内：vLLM server + bench（写入：临时容器） =="
  DEVS=()
  while IFS= read -r d; do [[ -n "$d" ]] && DEVS+=(--device="$d"); done < <(
      docker inspect "$REF_CTN" --format '{{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}' | tr ' ' '\n' | sed '/^$/d')
  echo "device_args=${DEVS[*]:-none}"
  [[ ${#DEVS[@]} -gt 0 ]] || { echo "!! 参考容器没有 device 配置，无法起 GPU 容器"; exit 14; }
  PRIV_ARGS=()
  [[ "$PRIV" == "true" ]] && PRIV_ARGS=(--privileged)
  MOUNT_ARGS=(-v "$MODEL_HOST":/model:ro)
  for spec in /opt/corex311 /usr/local/corex; do
      bind=$(docker inspect "$REF_CTN" --format '{{range .HostConfig.Binds}}{{.}}
{{end}}' | grep -E ":$spec(:|$)" | head -1)
      [[ -n "$bind" ]] && MOUNT_ARGS+=(-v "$bind")
  done
  echo "mount_args=${MOUNT_ARGS[*]}"

  docker run --rm -i --ipc=host --shm-size=16g --entrypoint bash \
      "${PRIV_ARGS[@]}" "${DEVS[@]}" \
      -e CUDA_VISIBLE_DEVICES="$GPUSEL" \
      -e VLLM_ENFORCE_CUDA_GRAPH=1 -e VLLM_USE_V1=1 \
      -e PROMPTS="$PROMPTS" -e WARMUPS="$WARMUPS" \
      -e CONCURRENCY_LIST="$CONCURRENCY_LIST" \
      -e IN_LEN="$IN_LEN" -e OUT_LEN="$OUT_LEN" -e MAX_LEN="$MAX_LEN" \
      -e CPU_RANGE="$CPU_RANGE" \
      "${MOUNT_ARGS[@]}" \
      "$IMAGE" -s <<'INNER'
set -uo pipefail
CLEAN=(env -u PYTHONPATH -u PYTHONHOME -u LD_PRELOAD -u LD_AUDIT -u LD_DEBUG -u LD_DEBUG_OUTPUT
       -u LD_BIND_NOT -u LD_PROFILE -u VLLM_TORCH_PROFILER_DIR -u PROFILER_CONFIG -u TORCH_PROFILER_DIR
       -u VLLM_HOST_OPT -u VLLM_HOST_OPT_INPUTS -u VLLM_HOST_OPT_ARENA -u VLLM_HOST_OPT_BOOKKEEPING
       -u VLLM_HOST_OPT_POSITIONS -u VLLM_HOST_OPT_METADATA -u VLLM_HOST_OPT_ARENA_MAX_REQS
       -u VLLM_HOST_OPT_DIAGNOSTICS -u TORCH_MODULE_ATTR_FASTPATH -u LIGHTHOST_SESSION -u LIGHTHOST_LIB)
PY=/opt/corex311/bin/python3
[[ -x "$PY" ]] || { echo "!! 镜像内没有 $PY"; exit 21; }
echo "-- 版本 / 干净度检查 --"
"${CLEAN[@]}" "$PY" - <<'PY'
import vllm, torch
print("vllm", vllm.__version__, "torch", torch.__version__)
print("device_count", torch.cuda.device_count())
p = torch.cuda.get_device_properties(0)
print("device", p.name, "mem_MB", round(p.total_memory/1024/1024))
PY
echo "litehost_env=$(env | grep -icE 'litehost' || true)"
echo "ld_preload=${LD_PRELOAD:-empty}"

echo "-- 启动 server（无 litehost worker、无 LD_PRELOAD） --"
SRV_ARGS=(
    -m vllm.entrypoints.openai.api_server
    --host 127.0.0.1 --port 8848 --model /model --trust_remote_code --dtype auto
    --max_model_len "$MAX_LEN" --distributed_executor_backend mp --pipeline_parallel_size 1
    --tensor_parallel_size 1 --data_parallel_size 1
    --gpu_memory_utilization 0.9 --kv_cache_dtype auto
    --enable_chunked_prefill --compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY", "mode":0}'
    --async-scheduling --no-enable-prefix-caching
)
taskset -c "$CPU_RANGE" "${CLEAN[@]}" "$PY" "${SRV_ARGS[@]}" > /tmp/server.log 2>&1 &
SPID=$!
cleanup() { kill "$SPID" 2>/dev/null || true; wait "$SPID" 2>/dev/null || true; }
trap cleanup EXIT

"${CLEAN[@]}" "$PY" - <<'PY'
import sys, time, urllib.request
deadline = time.time() + 600
while time.time() < deadline:
    try:
        with urllib.request.urlopen("http://127.0.0.1:8848/health", timeout=5) as r:
            if r.status == 200:
                print("server healthy"); sys.exit(0)
    except Exception:
        time.sleep(5)
print("server health timeout"); sys.exit(1)
PY
[[ $? -ne 0 ]] && { echo "!! server 未就绪"; tail -80 /tmp/server.log; exit 20; }

for BS in $CONCURRENCY_LIST; do
    echo
    echo "==== in${IN_LEN}/out${OUT_LEN} prompts=${PROMPTS} warmups=${WARMUPS} bs=${BS} (no litehost) ===="
    "${CLEAN[@]}" timeout 900 "$PY" -m vllm.entrypoints.cli.main bench serve \
        --backend vllm \
        --num_prompts "$PROMPTS" --num-warmups "$WARMUPS" --max-concurrency "$BS" \
        --dataset_name random --random_input_len "$IN_LEN" --random_output_len "$OUT_LEN" \
        --host 127.0.0.1 --port 8848 --model /model --trust_remote_code \
        --ignore_eos --top_p 1 --top_k -1 --temperature 0 --seed 42 \
        --save-result --result-dir /tmp --result_filename "clean_bs${BS}.json" \
        > /tmp/bench_bs${BS}.log 2>&1
    echo "bench_rc=$?"
    tail -45 /tmp/bench_bs${BS}.log || true
    echo "-- result json --"
    cat "/tmp/clean_bs${BS}.json" 2>/dev/null || echo "(无结果文件)"
    echo
done

echo "-- server.log 尾部 --"
tail -30 /tmp/server.log || true
cleanup
trap - EXIT
echo done
INNER
  echo "docker_rc=$?"

  echo
  echo "== 4. 结束后 GPU 状态（只读） =="
  "$IXSMI" --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -12 || true

  echo
  echo "### 完成：1024/1024 bs=$CONCURRENCY_LIST（no litehost）"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
