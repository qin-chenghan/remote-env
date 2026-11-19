#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。从 mock145_1355 的 rank0 trace 里提取 prefill/decode 一个 step 的
#       python_function 帧名与次数，用于和 32 同配置数据做帧级对齐。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TRACE=$(ls /home/huawei_ts_program/litehost_perf_opt/vllmBench/mock145_1355/timeline/rank0.*.gz 2>/dev/null | head -1)

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  [ -n "$TRACE" ] || { echo "!! 找不到 rank0 trace"; exit 3; }
  ls -lh "$TRACE"

  python3.11 - "$TRACE" <<'PY'
import collections, gzip, json, re, sys

trace = sys.argv[1]
with gzip.open(trace, "rt", encoding="utf-8") as f:
    ev = json.load(f)["traceEvents"]

def norm(name):
    name = re.sub(r" object at 0x[0-9a-f]+", "", name)
    name = re.sub(r"pybind11_builtins\.pybind11_detail_function_record_v1_"
                  r"system_libstdcpp_gxx_abi_1xxx_use_cxx11_abi_0",
                  "pybind11_method", name)
    name = re.sub(r"/tmp/torchinductor_root/[0-9a-z]+/[0-9a-z]+\.py",
                  "/tmp/torchinductor_root/X/kernel.py", name)
    return name

em = [e for e in ev if e.get("cat") == "python_function"
      and e.get("name", "").endswith(": execute_model")
      and "gpu_model_runner.py" in e.get("name", "")]

for scope in ("execute_context_1(128)_generation_0(0)",
              "execute_context_0(0)_generation_8(8)"):
    scopes = [e for e in ev if e.get("name") == scope and e.get("cat") == "user_annotation"]
    scopes.sort(key=lambda e: e["ts"])
    if not scopes:
        print(f"{scope}: NOT FOUND")
        continue
    sev = scopes[len(scopes) // 2]
    near = min(em, key=lambda e: abs(e["ts"] - sev["ts"]))
    t0, t1 = near["ts"], near["ts"] + near["dur"]
    key = (near.get("pid"), near.get("tid"))
    fr = collections.Counter()
    for e in ev:
        if (e.get("cat") == "python_function"
                and (e.get("pid"), e.get("tid")) == key
                and t0 <= e["ts"] < t1):
            fr[norm(e["name"])] += 1
    print(f"\n=== {scope}  occurrences={len(scopes)} idx={len(scopes)//2}")
    print(f"    anchor_dur_us={near['dur']:.1f}  frames={len(fr)}  calls={sum(fr.values())}")
    for n, c in sorted(fr.items(), key=lambda kv: -kv[1])[:12]:
        print(f"    {c:6d}  {n}")
    print("    -- mock 特有帧 --")
    for n, c in sorted(fr.items()):
        if "worker_patch" in n or "fake_graph" in n or "torchinductor" in n:
            print(f"    {c:6d}  {n}")
PY

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
