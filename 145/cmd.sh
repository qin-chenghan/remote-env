#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。确认 198 上 mock 代码的存放方式，以及 145 本地是否已更新到 ed8f593。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
PROBE=/tmp/probe198f.sh

{
  echo "### server: 145 -> 198"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
C=vllm

echo "== 1. mock 目录形态 =="
ls -ld /home/qch /home/qch/mock_vllm /home/qch/mock_vllm/mock_gpu /home/qch/tools/remote-env 2>&1 | head -8
readlink -f /home/qch/mock_vllm 2>/dev/null
echo "-- 仓库状态（若有）--"
git -C /home/qch/tools/remote-env log --oneline -1 2>&1 | head -2

echo "== 2. 当前 worker_patch.py（期望旧版 0188d4c5…）=="
md5sum /home/qch/mock_vllm/mock_gpu/worker_patch.py 2>/dev/null
grep -c "MOCK_TP_CPUS_DEFER\|MOCK_STACK_DUMP" /home/qch/mock_vllm/mock_gpu/worker_patch.py 2>/dev/null

echo "== 3. 容器内看到的同一路径 =="
docker exec $C bash -lc "readlink -f /home/qch/mock_vllm; md5sum /home/qch/mock_vllm/mock_gpu/worker_patch.py"

echo "== 4. bench 脚本是否也是软链 =="
ls -l /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base_mock_py312.sh
docker exec $C bash -lc "ls -l /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base_mock_py312.sh"
PROBE_EOF

  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE" 2>&1 | head -60

  echo "== 5. 145 本地仓库与 mock =="
  git -C /home/qch/tools/remote-env log --oneline -1 2>&1 | head -2
  md5sum /home/qch/mock_vllm/mock_gpu/worker_patch.py 2>/dev/null

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
