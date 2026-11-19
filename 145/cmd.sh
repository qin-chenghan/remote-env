#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：安装 lite 版 bench 脚本 → 先做一次帧级检查（只读）→ 后台启动 lite(H/G) bench。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

TGZ=/home/qch/transfer/litehost_tools.tgz
TOOLS=/home/huawei_ts_program/litehost_perf_opt
CONTAINER=corex5-py311-mock
MODEL=/home/model/Qwen3-32B-W8A8
TEST_ID="lite145_$(date +%H%M)"
TRACE=$(ls /home/huawei_ts_program/litehost_perf_opt/vllmBench/mock145_1355/timeline/rank0.*.gz 2>/dev/null | head -1)

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 安装 lite 版 bench 脚本 =="
  [ -f "$TGZ" ] || { echo "!! 缺 $TGZ"; exit 3; }
  tar xzf "$TGZ" -C "$TOOLS" || exit 1
  ls -lh "$TOOLS/vllmBench_lite_base.sh" "$TOOLS/vllmBench_lite_base_mock.sh" \
          "$TOOLS/vllmBench_lite_base_timeline.sh"
  grep -m1 -n "MOCK_DIR=/home" "$TOOLS/vllmBench_lite_base_mock.sh"

  echo "== 2. 帧级检查（mock145_1355 rank0，只读）=="
  if [ -n "$TRACE" ]; then
    python3.11 - "$TRACE" <<'PY'
import collections, gzip, json, re, sys
with gzip.open(sys.argv[1], "rt", encoding="utf-8") as f:
    ev = json.load(f)["traceEvents"]
def norm(n):
    n = re.sub(r" object at 0x[0-9a-f]+", "", n)
    n = re.sub(r"/tmp/torchinductor_root/[0-9a-z]+/[0-9a-z]+\.py",
               "/tmp/torchinductor_root/X/kernel.py", n)
    return n
em = [e for e in ev if e.get("cat") == "python_function"
      and e.get("name", "").endswith(": execute_model")
      and "gpu_model_runner.py" in e.get("name", "")]
for scope in ("execute_context_1(128)_generation_0(0)",
              "execute_context_0(0)_generation_8(8)"):
    s = sorted([e for e in ev if e.get("name") == scope and e.get("cat") == "user_annotation"],
               key=lambda e: e["ts"])
    if not s:
        print(scope, "NOT FOUND"); continue
    sev = s[len(s) // 2]
    near = min(em, key=lambda e: abs(e["ts"] - sev["ts"]))
    t0, t1 = near["ts"], near["ts"] + near["dur"]
    key = (near.get("pid"), near.get("tid"))
    fr = collections.Counter(norm(e["name"]) for e in ev
        if e.get("cat") == "python_function"
        and (e.get("pid"), e.get("tid")) == key and t0 <= e["ts"] < t1)
    print(f"{scope}: occurrences={len(s)} frames={len(fr)} calls={sum(fr.values())}")
    for n in sorted(fr):
        if "worker_patch" in n or "fake_graph" in n:
            print(f"   {fr[n]:6d}  {n}")
PY
  else
    echo "找不到 trace，跳过"
  fi

  echo "== 3. 前置检查 =="
  docker ps --filter "name=$CONTAINER" --format '{{.Names}} {{.Status}}' | grep -q Up \
    || { echo "!! 容器没在跑"; exit 3; }
  [ -f "$MODEL/config.json" ] || { echo "!! 缺模型"; exit 3; }
  if ss -ltn 2>/dev/null | grep -q ':8948 '; then
    echo "!! 8948 被占用"; exit 5
  fi

  echo "== 4. 启动 lite(H/G) bench（后台）=="
  echo "TEST_ID=$TEST_ID"
  docker exec -d "$CONTAINER" bash -lc "cd $TOOLS && \
    MODEL_PATH=$MODEL TEST_ID=$TEST_ID HOST_MEASURE=lite \
    nohup bash vllmBench_lite_base_mock.sh \
    > /home/qch/transfer/run_$TEST_ID.log 2>&1"
  sleep 25
  tail -10 "/home/qch/transfer/run_$TEST_ID.log" 2>/dev/null || echo "(日志未出现)"

  echo "== 5. 后续查看 =="
  echo "日志：/home/qch/transfer/run_$TEST_ID.log"
  echo "结果：$TOOLS/vllmBench/$TEST_ID/host_summary/report.txt"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
