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
PROFILE_HOST="${PROFILE_HOST:-/home/qch/qwen06_profile}"
PROMPTS="${PROMPTS:-16}"
WARMUPS="${WARMUPS:-4}"
CONCURRENCY="${CONCURRENCY:-8}"
IN_LEN="${IN_LEN:-1024}"
OUT_LEN="${OUT_LEN:-1024}"
MAX_LEN="${MAX_LEN:-4096}"
PORT_IN="${PORT_IN:-8000}"
STAMP="$(date +%Y%m%d-%H%M%S)"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### script: vllm-timeline-31-v1（torch profiler timeline，不含 litehost / 不做 H/G 拆分）"
  echo
  echo "### 本轮写入：1) 建 $PROFILE_HOST 存放 trace；"
  echo "###           2) 起 --rm 容器，server 带 VLLM_TORCH_PROFILER_DIR=/profile；"
  echo "###           3) bench 用 --profile 包住 in${IN_LEN}/out${OUT_LEN} bs=$CONCURRENCY（prompts=$PROMPTS warmups=$WARMUPS）；"
  echo "###           4) trace 落盘后做流式汇总（GPU busy / stream 空闲 / top CPU op），原文件保留。"
  echo "###           不动模型、不改系统。预计 8-15 分钟（服务启动约 255 s）。"
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
  echo "-- 磁盘 --"
  df -BG /home | tail -1

  echo
  echo "== 1. 准备 trace 目录（写入：新建目录） =="
  mkdir -p "$PROFILE_HOST"
  echo "profile_host=$PROFILE_HOST"
  ls -ld "$PROFILE_HOST"
  echo "已有 trace 文件："
  find "$PROFILE_HOST" -maxdepth 1 -type f -printf '%f %s B\n' 2>/dev/null | head -10 || true

  echo
  echo "== 2. 容器内：vLLM server + 带 profiler 的 bench（写入：临时容器 + trace） =="
  docker run --rm -i --network=host --ipc=host --shm-size=16g \
      --device=/dev/mxcd \
      $(for d in /dev/dri/card* /dev/dri/renderD*; do [[ -e "$d" ]] && printf -- '--device=%s ' "$d"; done) \
      -e MACA_VISIBLE_DEVICES="$GPUSEL" -e CUDA_VISIBLE_DEVICES="$GPUSEL" \
      -e PROMPTS="$PROMPTS" -e WARMUPS="$WARMUPS" -e CONCURRENCY="$CONCURRENCY" \
      -e IN_LEN="$IN_LEN" -e OUT_LEN="$OUT_LEN" \
      -e MAX_LEN="$MAX_LEN" -e PORT_IN="$PORT_IN" \
      -e VLLM_TORCH_PROFILER_DIR=/profile \
      -v "$MODEL_DIR":/model:ro \
      -v "$PROFILE_HOST":/profile \
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
import torch.profiler as tp
print("torch.profiler ok", hasattr(tp, "profile"))
PY

echo "-- server/bench CLI 探测 --"
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
PROFILE_FLAG=()
grep -q -- '--profile' /tmp/bench_help.txt && PROFILE_FLAG=(--profile) || echo "!! bench 无 --profile，将用 HTTP 端点手动开停"
echo "bench_cmd=${BENCH[*]} profile_flag=${PROFILE_FLAG[*]:-none}"

SRV_ARGS=(
    --host 127.0.0.1 --port "$PORT_IN" --model /model
    --trust-remote-code --dtype auto
    --max-model-len "$MAX_LEN" --tensor-parallel-size 1
    --gpu-memory-utilization 0.9
    "${EXTRA[@]}"
)
echo "-- 启动 server（VLLM_TORCH_PROFILER_DIR=$VLLM_TORCH_PROFILER_DIR）：${SRV_ARGS[*]} --"
python3 -m vllm.entrypoints.openai.api_server "${SRV_ARGS[@]}" > /tmp/server.log 2>&1 &
SPID=$!
cleanup() { kill "$SPID" 2>/dev/null || true; wait "$SPID" 2>/dev/null || true; }
trap cleanup EXIT

python3 - "$PORT_IN" <<'PY'
import sys, time, urllib.request
port = int(sys.argv[1])
deadline = time.time() + 600
while time.time() < deadline:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as r:
            if r.status == 200:
                print("server healthy")
                sys.exit(0)
    except Exception:
        time.sleep(5)
print("server health timeout")
sys.exit(1)
PY
[[ $? -ne 0 ]] && { echo "!! server 未就绪"; tail -60 /tmp/server.log; exit 5; }

mkdir -p /profile
BEFORE=$(find /profile -maxdepth 1 -type f | wc -l)
echo "profile_files_before=$BEFORE"

echo
echo "==== profiled bench: in${IN_LEN}/out${OUT_LEN} prompts=${PROMPTS} warmups=${WARMUPS} bs=${CONCURRENCY} ===="
if [[ ${#PROFILE_FLAG[@]} -gt 0 ]]; then
    timeout 900 "${BENCH[@]}" \
        --backend vllm \
        --num_prompts "$PROMPTS" --num-warmups "$WARMUPS" --max-concurrency "$CONCURRENCY" \
        --dataset_name random --random_input_len "$IN_LEN" --random_output_len "$OUT_LEN" \
        --host 127.0.0.1 --port "$PORT_IN" --model /model --trust-remote-code \
        --ignore_eos --top_p 1 --top_k -1 --temperature 0 --seed 42 \
        --save-result --result-dir /tmp --result_filename "prof_bs${CONCURRENCY}_in${IN_LEN}_out${OUT_LEN}.json" \
        "${PROFILE_FLAG[@]}" \
        > /tmp/bench.log 2>&1
    echo "bench_rc=$?"
else
    python3 - "$PORT_IN" <<'PY'
import sys, urllib.request
port = sys.argv[1]
req = urllib.request.Request(f"http://127.0.0.1:{port}/start_profile", method="POST")
urllib.request.urlopen(req, timeout=30).read()
print("start_profile ok")
PY
    timeout 900 "${BENCH[@]}" \
        --backend vllm \
        --num_prompts "$PROMPTS" --num-warmups "$WARMUPS" --max-concurrency "$CONCURRENCY" \
        --dataset_name random --random_input_len "$IN_LEN" --random_output_len "$OUT_LEN" \
        --host 127.0.0.1 --port "$PORT_IN" --model /model --trust-remote-code \
        --ignore_eos --top_p 1 --top_k -1 --temperature 0 --seed 42 \
        --save-result --result-dir /tmp --result_filename "prof_bs${CONCURRENCY}_in${IN_LEN}_out${OUT_LEN}.json" \
        > /tmp/bench.log 2>&1
    echo "bench_rc=$?"
    python3 - "$PORT_IN" <<'PY'
import sys, urllib.request
port = sys.argv[1]
req = urllib.request.Request(f"http://127.0.0.1:{port}/stop_profile", method="POST")
urllib.request.urlopen(req, timeout=60).read()
print("stop_profile ok")
PY
fi
tail -35 /tmp/bench.log || true
echo "-- result json --"
cat "/tmp/prof_bs${CONCURRENCY}_in${IN_LEN}_out${OUT_LEN}.json" 2>/dev/null || echo "(无结果文件)"

echo
echo "-- 等待 trace 落盘（最多 300 s，要求大小稳定 15 s） --"
python3 <<'PY'
import glob, os, time, sys
deadline = time.time() + 300
last = None
stable_since = None
while time.time() < deadline:
    files = glob.glob("/profile/*.json") + glob.glob("/profile/*.json.gz")
    if files:
        sig = tuple(sorted((os.path.basename(f), os.path.getsize(f)) for f in files))
        if sig == last:
            if stable_since is None:
                stable_since = time.time()
            elif time.time() - stable_since > 15:
                print("trace 已稳定：%d 个文件" % len(files))
                sys.exit(0)
        else:
            last = sig
            stable_since = None
            print("检测到 trace 文件：", ", ".join("%s=%.1fMB" % (os.path.basename(f), os.path.getsize(f)/1048576) for f in files))
    time.sleep(5)
print("等待 trace 超时")
sys.exit(1)
PY
echo "trace_wait_rc=$?"

echo "-- /profile 内容 --"
ls -lh /profile | head -20

echo
echo "-- trace 汇总（流式解析，不整体载入内存） --"
python3 - <<'PY'
import glob, gzip, json, os, sys, collections

paths = sorted(glob.glob("/profile/*.json")) + sorted(glob.glob("/profile/*.json.gz"))
if not paths:
    print("没有 trace 文件，跳过汇总")
    sys.exit(0)

for path in paths:
    print("==", os.path.basename(path), "%.1f MB" % (os.path.getsize(path)/1048576))
    opener = gzip.open if path.endswith(".gz") else open
    span_lo, span_hi = None, None
    cat_count = collections.Counter()
    cat_dur = collections.Counter()
    kernels = []          # (ts, dur, stream)
    cpu_dur = collections.Counter()
    cpu_cnt = collections.Counter()
    ann_dur = collections.Counter()
    n_events = 0
    with opener(path, "rt", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line or not line.startswith("{"):
                continue
            line = line.rstrip(",")
            try:
                ev = json.loads(line)
            except Exception:
                continue
            n_events += 1
            ph = ev.get("ph")
            if ph != "X":
                continue
            ts = ev.get("ts"); dur = ev.get("dur")
            if ts is None or dur is None:
                continue
            lo, hi = ts, ts + dur
            span_lo = lo if span_lo is None or lo < span_lo else span_lo
            span_hi = hi if span_hi is None or hi > span_hi else span_hi
            cat = ev.get("cat", "")
            cat_count[cat] += 1
            cat_dur[cat] += dur
            if cat == "kernel":
                args = ev.get("args") or {}
                kernels.append((ts, dur, args.get("stream", ev.get("tid"))))
            elif cat in ("cpu_op", "user_annotation"):
                name = ev.get("name", "?")
                cpu_dur[name] += dur
                cpu_cnt[name] += 1
            elif cat == "gpu_user_annotation":
                ann_dur[ev.get("name", "?")] += dur
    span = (span_hi - span_lo) if span_lo is not None else 0
    print("  events(parsed)=%d span=%.3f s" % (n_events, span/1e6 if span else 0))
    for cat, cnt in cat_count.most_common(8):
        print("  cat %-22s events=%-8d dur=%.3f s" % (cat or "(none)", cnt, cat_dur[cat]/1e6))

    def merge_busy(iv):
        iv = sorted(iv)
        total = 0.0
        cur_lo = cur_hi = None
        for lo, hi in iv:
            if cur_lo is None:
                cur_lo, cur_hi = lo, hi
            elif lo <= cur_hi:
                cur_hi = max(cur_hi, hi)
            else:
                total += cur_hi - cur_lo
                cur_lo, cur_hi = lo, hi
        if cur_lo is not None:
            total += cur_hi - cur_lo
        return total

    if kernels:
        busy = merge_busy([(ts, ts+dur) for ts, dur, _ in kernels])
        print("  kernels=%d  GPU_busy=%.3f s (%.1f%% of span)" % (len(kernels), busy/1e6, 100*busy/span if span else 0))
        by_stream = collections.defaultdict(list)
        for ts, dur, st in kernels:
            by_stream[st].append((ts, ts+dur))
        for st, iv in sorted(by_stream.items(), key=lambda kv: -merge_busy(kv[1]))[:6]:
            b = merge_busy(iv)
            iv.sort()
            gaps = 0.0
            gmax = 0.0
            for (a_lo, a_hi), (b_lo, _) in zip(iv, iv[1:]):
                g = b_lo - a_hi
                if g > 0:
                    gaps += g
                    gmax = max(gmax, g)
            print("  stream %-10s kernels=%-6d busy=%.3f s idle_gaps=%.3f s max_gap=%.1f ms"
                  % (str(st), len(iv), b/1e6, gaps/1e6, gmax/1000))
    print("  top cpu_op by total dur:")
    for name, d in cpu_dur.most_common(15):
        print("    %-48s %8.3f s  n=%d" % (name[:48], d/1e6, cpu_cnt[name]))
    if ann_dur:
        print("  top gpu_user_annotation by total dur:")
        for name, d in ann_dur.most_common(10):
            print("    %-48s %8.3f s" % (name[:48], d/1e6))
PY

echo "-- server.log 尾部 --"
tail -20 /tmp/server.log || true
cleanup
trap - EXIT
echo done
INNER
  echo "docker_rc=$?"

  echo
  echo "== 3. trace 文件与打包（只读 + 压缩） =="
  ls -lh "$PROFILE_HOST" | head -20
  find "$PROFILE_HOST" -maxdepth 1 -type f -name '*.json*' -exec sha256sum {} \; 2>/dev/null | head -10 || true
  TAR="$PROFILE_HOST/timeline-31-${STAMP}.tar.gz"
  ( cd "$PROFILE_HOST" && tar -czf "$TAR" --exclude="$(basename "$TAR")" . ) 2>/dev/null \
      && du -h "$TAR" || echo "(打包失败或无文件)"
  echo "trace_dir=$PROFILE_HOST"

  echo
  echo "== 4. 结束后 GPU 状态（只读） =="
  mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -20 || true

  echo
  echo "### 完成：timeline（in${IN_LEN}/out${OUT_LEN} bs=$CONCURRENCY），原始 trace 在 $PROFILE_HOST"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
