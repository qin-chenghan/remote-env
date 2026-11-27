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
MAX_SEQS="${MAX_SEQS:-8}"
IN_LEN="${IN_LEN:-1024}"
OUT_LEN="${OUT_LEN:-1024}"
MAX_LEN="${MAX_LEN:-4096}"
STAMP="$(date +%Y%m%d-%H%M%S)"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### script: vllm-timeline-31-v2（离线 LLM.generate + torch.profiler；v1 的 /start_profile 在该版本返回 404）"
  echo
  echo "### 本轮写入：1) 建 $PROFILE_HOST 存放 trace；"
  echo "###           2) 起 --rm 容器，离线 LLM（max_num_seqs=$MAX_SEQS），先 bs=$MAX_SEQS 预热；"
  echo "###           3) 用 torch.profiler 包住 in${IN_LEN}/out${OUT_LEN}、${PROMPTS} 条请求的 generate；"
  echo "###           4) 打印 key_averages（self CPU / CUDA）并导出 Perfetto JSON + 流式汇总，原文件保留。"
  echo "###           不动模型、不改系统。预计 6-12 分钟（引擎初始化含图编译约 255 s）。"
  set +x

  echo
  echo "== 0. 前置检查（只读） =="
  date
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' 2>/dev/null | grep -F "$IMAGE" || {
      echo "!! 找不到镜像 $IMAGE"; exit 2; }
  if [[ -f "$MODEL_DIR/config.json" && -f "$MODEL_DIR/model.safetensors" ]]; then
      ls -lh "$MODEL_DIR" | head -8
      echo "model_size=$(stat -c %s "$MODEL_DIR/model.safetensors")"
  else
      echo "!! 模型不完整：$MODEL_DIR"; exit 2
  fi
  mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -20 || true
  if mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | grep -qiE 'python|vllm|ray|pt_main'; then
      echo "!! GPU 上有进程，按共享卡策略退出"; exit 3
  fi
  df -BG /home | tail -1

  echo
  echo "== 1. 准备 trace 目录（写入：新建目录） =="
  mkdir -p "$PROFILE_HOST"
  ls -ld "$PROFILE_HOST"
  find "$PROFILE_HOST" -maxdepth 1 -type f -printf '%f %s B\n' 2>/dev/null | head -10 || true

  echo
  echo "== 2. 容器内：离线 LLM + torch.profiler（写入：临时容器 + trace） =="
  docker run --rm -i --network=host --ipc=host --shm-size=16g \
      --device=/dev/mxcd \
      $(for d in /dev/dri/card* /dev/dri/renderD*; do [[ -e "$d" ]] && printf -- '--device=%s ' "$d"; done) \
      -e MACA_VISIBLE_DEVICES="$GPUSEL" -e CUDA_VISIBLE_DEVICES="$GPUSEL" \
      -e PROMPTS="$PROMPTS" -e MAX_SEQS="$MAX_SEQS" \
      -e IN_LEN="$IN_LEN" -e OUT_LEN="$OUT_LEN" -e MAX_LEN="$MAX_LEN" \
      -e VLLM_ENABLE_V1_MULTIPROCESSING=0 \
      -v "$MODEL_DIR":/model:ro \
      -v "$PROFILE_HOST":/profile \
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

python3 - <<'PY'
import dataclasses, os, random, time, gzip, shutil, glob, json, collections
import torch
from vllm import LLM, SamplingParams

PROMPTS   = int(os.environ["PROMPTS"])
MAX_SEQS  = int(os.environ["MAX_SEQS"])
IN_LEN    = int(os.environ["IN_LEN"])
OUT_LEN   = int(os.environ["OUT_LEN"])
MAX_LEN   = int(os.environ["MAX_LEN"])

from vllm.engine.arg_utils import EngineArgs
fields = {f.name for f in dataclasses.fields(EngineArgs)}
wanted = {
    "model": "/model",
    "trust_remote_code": True,
    "dtype": "auto",
    "max_model_len": MAX_LEN,
    "tensor_parallel_size": 1,
    "gpu_memory_utilization": 0.9,
    "max_num_seqs": MAX_SEQS,
    "enable_prefix_caching": False,
    "enable_chunked_prefill": True,
    "async_scheduling": True,
    "compilation_config": {"cudagraph_mode": "FULL_DECODE_ONLY", "mode": 0},
}
kwargs = {k: v for k, v in wanted.items() if k in fields}
print("engine_kwargs:", sorted(kwargs))

t0 = time.time()
try:
    llm = LLM(**kwargs)
except Exception as e:
    print("!! full kwargs failed:", type(e).__name__, e)
    minimal = {k: kwargs[k] for k in ("model", "trust_remote_code", "dtype", "max_model_len",
                                      "gpu_memory_utilization", "max_num_seqs") if k in kwargs}
    print("retry with:", sorted(minimal))
    llm = LLM(**minimal)
print("engine init %.1f s" % (time.time() - t0))

def make_prompts(n, length, seed=42):
    rnd = random.Random(seed)
    return [{"prompt_token_ids": [rnd.randrange(0, 1000) for _ in range(length)]} for _ in range(n)]

sp = SamplingParams(max_tokens=OUT_LEN, temperature=0.0, top_p=1.0, top_k=-1, ignore_eos=True)
sp_warm = SamplingParams(max_tokens=32, temperature=0.0, top_p=1.0, top_k=-1, ignore_eos=True)

print("-- 预热（%d 条 / %d token，触发编译与 cudagraph 捕获） --" % (MAX_SEQS, 32))
t0 = time.time()
llm.generate(make_prompts(MAX_SEQS, IN_LEN), sp_warm)
print("warmup %.1f s" % (time.time() - t0))

acts = [torch.profiler.ProfilerActivity.CPU]
have_cuda_act = False
if hasattr(torch.profiler.ProfilerActivity, "CUDA"):
    acts.append(torch.profiler.ProfilerActivity.CUDA)
    have_cuda_act = True
print("profiler_activities:", [a.name for a in acts])

prompts = make_prompts(PROMPTS, IN_LEN)
wall = 0.0
prof = None
for use_acts, label in ((acts, "cpu+cuda" if have_cuda_act else "cpu"), (acts[:1], "cpu-only")):
    prof = torch.profiler.profile(activities=use_acts, record_shapes=False,
                                  profile_memory=False, with_stack=False)
    try:
        prof.__enter__()
        t0 = time.time()
        outs = llm.generate(prompts, sp)
        wall = time.time() - t0
        prof.__exit__(None, None, None)
        print("profiled generate ok (%s): %.2f s" % (label, wall))
        break
    except Exception as e:
        print("!! profiler with %s failed: %s: %s" % (label, type(e).__name__, e))
        try:
            prof.__exit__(None, None, None)
        except Exception:
            pass
        prof = None
else:
    raise SystemExit("profiler 无法启动")

if prof is None:
    raise SystemExit("profiler 无法启动")

n_out = sum(len(o.outputs[0].token_ids) for o in outs)
print("generated_tokens=%d (=%d x %d) wall=%.2f s  out_tok/s=%.1f"
      % (n_out, PROMPTS, OUT_LEN, wall, n_out / wall))

print()
print("==== key_averages by self CPU time (top 30) ====")
try:
    print(prof.key_averages().table(sort_by="self_cpu_time_total", row_limit=30,
                                    max_name_column_width=60))
except Exception as e:
    print("table(cpu) failed:", e)

cuda_sort = None
for cand in ("self_cuda_time_total", "self_device_time_total"):
    try:
        prof.key_averages().table(sort_by=cand, row_limit=1)
        cuda_sort = cand
        break
    except Exception:
        continue
if cuda_sort:
    print()
    print("==== key_averages by %s (top 25) ====" % cuda_sort)
    print(prof.key_averages().table(sort_by=cuda_sort, row_limit=25,
                                    max_name_column_width=60))

os.makedirs("/profile", exist_ok=True)
trace = "/profile/offline_bs%d_in%d_out%d.json" % (MAX_SEQS, IN_LEN, OUT_LEN)
t0 = time.time()
prof.export_chrome_trace(trace)
print("export trace %.1f s -> %s (%.1f MB)" % (time.time() - t0, trace,
      os.path.getsize(trace) / 1048576 if os.path.exists(trace) else -1))

if os.path.exists(trace):
    with open(trace, "rb") as f_in, gzip.open(trace + ".gz", "wb", compresslevel=6) as f_out:
        shutil.copyfileobj(f_in, f_out)
    print("gz %.1f MB" % (os.path.getsize(trace + ".gz") / 1048576))

    print()
    print("---- trace 流式汇总 ----")
    span_lo = span_hi = None
    cat_count = collections.Counter()
    cat_dur = collections.Counter()
    kernels = []
    cpu_dur = collections.Counter()
    cpu_cnt = collections.Counter()
    n = 0
    with open(trace, "r", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                ev = json.loads(line.rstrip(","))
            except Exception:
                continue
            n += 1
            if ev.get("ph") != "X":
                continue
            ts, dur = ev.get("ts"), ev.get("dur")
            if ts is None or dur is None:
                continue
            span_lo = ts if span_lo is None or ts < span_lo else span_lo
            span_hi = ts + dur if span_hi is None or ts + dur > span_hi else span_hi
            cat = ev.get("cat", "")
            cat_count[cat] += 1
            cat_dur[cat] += dur
            if cat.lower() == "kernel":
                kernels.append((ts, dur, (ev.get("args") or {}).get("stream", ev.get("tid"))))
            elif cat in ("cpu_op", "user_annotation"):
                name = ev.get("name", "?")
                cpu_dur[name] += dur
                cpu_cnt[name] += 1
    span = (span_hi - span_lo) if span_lo is not None else 0
    print("events=%d span=%.3f s" % (n, span / 1e6 if span else 0))
    for cat, cnt in cat_count.most_common(8):
        print("cat %-22s events=%-8d dur=%.3f s" % (cat or "(none)", cnt, cat_dur[cat] / 1e6))

    def merge_busy(iv):
        iv.sort()
        total = 0.0
        lo = hi = None
        for a, b in iv:
            if lo is None:
                lo, hi = a, b
            elif a <= hi:
                hi = max(hi, b)
            else:
                total += hi - lo
                lo, hi = a, b
        if lo is not None:
            total += hi - lo
        return total

    if kernels:
        busy = merge_busy([(ts, ts + dur) for ts, dur, _ in kernels])
        print("kernels=%d GPU_busy=%.3f s (%.1f%% of span)" % (len(kernels), busy / 1e6,
              100 * busy / span if span else 0))
        per = collections.defaultdict(list)
        for ts, dur, st in kernels:
            per[st].append((ts, ts + dur))
        for st, iv in sorted(per.items(), key=lambda kv: -merge_busy(kv[1]))[:6]:
            b = merge_busy(iv)
            gaps = gmax = 0.0
            for (a_lo, a_hi), (b_lo, _) in zip(iv, iv[1:]):
                g = b_lo - a_hi
                if g > 0:
                    gaps += g
                    gmax = max(gmax, g)
            print("stream %-10s kernels=%-6d busy=%.3f s idle_gaps=%.3f s max_gap=%.1f ms"
                  % (str(st), len(iv), b / 1e6, gaps / 1e6, gmax / 1000))
    print("top cpu_op by total dur:")
    for name, d in cpu_dur.most_common(15):
        print("  %-50s %8.3f s n=%d" % (name[:50], d / 1e6, cpu_cnt[name]))
PY

echo "-- /profile 内容 --"
ls -lh /profile | head -20
echo done
INNER
  echo "docker_rc=$?"

  echo
  echo "== 3. trace 文件与打包（只读 + 压缩） =="
  ls -lh "$PROFILE_HOST" | head -20
  find "$PROFILE_HOST" -maxdepth 1 -type f \( -name '*.json' -o -name '*.json.gz' \) \
      -exec sha256sum {} \; 2>/dev/null | head -10 || true

  echo
  echo "== 4. 结束后 GPU 状态（只读） =="
  mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -20 || true

  echo
  echo "### 完成：timeline（offline, in${IN_LEN}/out${OUT_LEN} max_num_seqs=$MAX_SEQS），trace 在 $PROFILE_HOST"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
