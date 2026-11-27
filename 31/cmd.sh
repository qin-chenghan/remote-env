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

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### script: hw-report-v1（静态只读 + 单卡短微基准，不涉及模型权重）"
  echo
  echo "### 本轮写入：启动一个 --rm 临时容器（镜像 $IMAGE），用 GPU $GPUSEL"
  echo "###           跑 torch 带宽/GEMM 微基准，约 1-2 分钟；不装包、不改配置、不留容器。"
  echo "###           其余全部只读。"
  set +x

  echo
  echo "== 0. 主机（只读） =="
  date
  uname -srm
  grep -E '^(NAME|VERSION|PRETTY_NAME)=' /etc/os-release
  echo "nproc=$(nproc)"
  lscpu | grep -E '^(Model name|Socket\(s\)|Core\(s\) per socket|NUMA node\(s\)|NUMA node[0-9] CPU\(s\)):' || true
  echo "-- 内存 --"
  free -g | head -3
  echo "-- 磁盘 --"
  df -BG / /home 2>/dev/null | tail -2

  echo
  echo "== 1. mx-smi 规格（只读） =="
  mx-smi 2>&1 | head -8 || true
  echo "-- -L --"
  mx-smi -L 2>&1 | head -12 || true
  for flag in --show-version --show-sysinfo --show-hwinfo --show-memory \
              --show-clock --show-dpm --show-hbm-bandwidth --show-pcie \
              --show-pcie-bandwidth --show-board-power --show-vpu; do
      echo "-- mx-smi -i $GPUSEL $flag --"
      mx-smi -i "$GPUSEL" "$flag" 2>&1 | head -40 || true
  done

  echo
  echo "== 2. GPU 占用（只读；有进程则跳过微基准） =="
  busy=0
  mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -30 || true
  if mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | grep -qiE 'python|vllm|ray|pt_main'; then
      busy=1
      echo "!! 检测到 GPU 上有进程，本轮不做微基准，只出静态信息"
  else
      echo "GPU 空闲，继续微基准"
  fi

  echo
  echo "== 3. 容器内 torch 微基准（写入：临时容器，即用即删） =="
  echo "-- 现有容器/镜像 --"
  docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null | head -15 || true
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' 2>/dev/null | grep -iE 'metax|maca' | head -10 || true
  echo "-- 既有容器的设备/特权配置（只读参考） --"
  ref=$(docker ps -a --format '{{.Names}}' 2>/dev/null | head -1)
  if [[ -n "${ref:-}" ]]; then
      docker inspect "$ref" --format 'name={{.Name}} privileged={{.HostConfig.Privileged}} ipc={{.HostConfig.IpcMode}} net={{.HostConfig.NetworkMode}} shm={{.HostConfig.ShmSize}}' 2>/dev/null || true
      docker inspect "$ref" --format '{{range .HostConfig.Devices}}device={{.PathOnHost}} {{end}}' 2>/dev/null || true
      docker inspect "$ref" --format 'binds={{range .HostConfig.Binds}}{{.}} {{end}}' 2>/dev/null || true
  fi

  if [[ "$busy" == "1" ]]; then
      echo "跳过微基准"
  else
      PRIV=()
      if docker inspect "$ref" --format '{{.HostConfig.Privileged}}' 2>/dev/null | grep -q true; then
          PRIV=(--privileged)
      fi
      DEV_ARGS=(--device=/dev/mxcd)
      for d in /dev/dri/card* /dev/dri/renderD*; do
          [[ -e "$d" ]] && DEV_ARGS+=(--device="$d")
      done

      echo "-- docker run（$IMAGE, MACA_VISIBLE_DEVICES=$GPUSEL） --"
      timeout 600 docker run --rm -i --network=host --ipc=host --shm-size=8g \
          "${PRIV[@]}" "${DEV_ARGS[@]}" \
          -e MACA_VISIBLE_DEVICES="$GPUSEL" -e CUDA_VISIBLE_DEVICES="$GPUSEL" \
          "$IMAGE" python3 - <<'PY'
import json, time, torch

def props():
    p = torch.cuda.get_device_properties(0)
    d = {}
    for k in ("name", "total_memory", "multi_processor_count", "major", "minor"):
        d[k] = getattr(p, k, None)
    for k in ("L2_cache_size", "memory_clock_rate", "memory_bus_width"):
        if hasattr(p, k):
            d[k] = getattr(p, k)
    return d, str(p)

print("torch", torch.__version__)
print("torch.cuda.version", getattr(torch.version, "cuda", None))
print("device_count", torch.cuda.device_count())
d, raw = props()
print("device_props", json.dumps(d))
print("device_props_raw", raw)
torch.cuda.init()
print("mem_get_info", torch.cuda.mem_get_info())

def bench(fn, warmup=3, iters=10):
    for _ in range(warmup):
        fn()
    torch.cuda.synchronize()
    s = torch.cuda.Event(enable_timing=True)
    e = torch.cuda.Event(enable_timing=True)
    s.record()
    for _ in range(iters):
        fn()
    e.record()
    torch.cuda.synchronize()
    return s.elapsed_time(e) / 1000.0 / iters

N = 1 << 29  # 每张量 1 GiB（bf16）
x = torch.randn(N, device="cuda", dtype=torch.bfloat16)
y = torch.randn(N, device="cuda", dtype=torch.bfloat16)
z = torch.empty_like(x)
nb = N * 2  # 单张量字节数

t = bench(lambda: y.copy_(x), iters=10)
print("BW copy   %.1f GB/s (%.4f ms)" % (2 * nb / t / 1e9, t * 1e3))
t = bench(lambda: torch.add(x, y, out=z), iters=10)
print("BW triad  %.1f GB/s (%.4f ms)" % (3 * nb / t / 1e9, t * 1e3))
t = bench(lambda: x.sum(), iters=10)
print("BW reduce %.1f GB/s (%.4f ms)" % (nb / t / 1e9, t * 1e3))
del x, y, z
torch.cuda.empty_cache()

def gemm(dtype, n, warmup, iters, tag):
    try:
        a = torch.randn(n, n, device="cuda", dtype=dtype)
        b = torch.randn(n, n, device="cuda", dtype=dtype)
        f = lambda: torch.mm(a, b)
        t = bench(f, warmup=warmup, iters=iters)
        print("GEMM %-5s %5d^3  %.1f TFLOPS (%.3f ms)" % (tag, n, 2 * n ** 3 / t / 1e12, t * 1e3))
    except Exception as ex:
        print("GEMM %-5s %5d^3  FAILED %s" % (tag, n, ex))
    finally:
        try:
            del a, b
        except Exception:
            pass
        torch.cuda.empty_cache()

for n, w, i in ((4096, 3, 10), (8192, 2, 5), (16384, 2, 3)):
    gemm(torch.bfloat16, n, w, i, "bf16")
    gemm(torch.float16, n, w, i, "fp16")
gemm(torch.float32, 8192, 2, 5, "fp32")
print("done")
PY
      echo "docker_rc=$?"

      echo "-- 运行后 mx-smi 状态（只读） --"
      mx-smi 2>&1 | sed -n '/Process:/,/End of Log/p' | head -20 || true
  fi

  echo
  echo "### 完成：静态规格 + 单卡实测（若 GPU 空闲）"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
