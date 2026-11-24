#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：① 只读取证 100823 那 9 分钟的 capture 是不是在 JIT 编译、以及哪个超时在 600s 踢人；
#       ② FIX=1 时从 145 的仓库 clone 同步新 mock/脚本到 145 部署目录和 198（都先备份）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
FIX="${FIX:-0}"
PROBE=/tmp/probe198i.sh

SRC_MOCK=/home/qch/mock_vllm/mock_gpu/worker_patch.py
SRC_TOOL=/home/qch/tools/remote-env/litehost_toolkit          # 145 上的仓库 clone（git pull 后即最新）
HOST_TOOL=/home/huawei_ts_program/litehost_perf_opt            # 145 上实际运行的部署目录
DOCKER_MOCK=/home/qch/mock_vllm/mock_gpu/worker_patch.py
DOCKER_TOOL=/home/huawei_ts_program/litehost_perf_opt
RUN=/home/huawei_ts_program/litehost_perf_opt/vllmBench/py312_litehost_gap_20261124_100823

{
  echo "### server: 145 -> 198  (FIX=$FIX)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  echo "== 0. 100823 卡住的 9 分钟在做什么（只读）=="
  cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
# 不带 -i：否则 docker 会从 stdin 抽走本探针脚本剩余的行
D() { docker exec vllm bash -lc "$1" 2>&1 | sed '/^Authorized users only/d'; }
D 'echo "-- torch/inductor 缓存语义"; /usr/local/bin/python3 -c "import inspect,torch,torch._inductor.codecache as c;print(\"torch\",torch.__version__);print(\"header_dir\",getattr(c,\"_HEADER_DIR\",\"NA\"));print(inspect.getsource(c.default_cache_dir).strip())" 2>&1 | tail -12'
D 'echo "-- 11:14 之后到死亡前的完整主日志（略去 shm 刷屏）"; L=RUNLOG; grep -cEi "compil" $L; grep -E "11:(1[4-9]|2[0-9]):" $L | grep -vE "No available shared memory|shm_broadcast" | tail -35'
D 'echo "-- 死亡前 30 行（含 worker 自己的报错）"; L=RUNLOG; tail -n 60 $L | cut -c1-160'
D 'echo "-- pin 的 cache 目录在 11-24 有没有写入"; C=/home/huawei_ts_program/inductor_cache_py312; find $C -type f | wc -l; find $C -newermt "2026-11-24 00:00" -printf "%TY-%Tm-%Td %TH:%TM %p\n" 2>/dev/null | sort | tail -8; ls -la --time-style=long-iso $C 2>&1 | head -6'
D 'echo "-- /tmp 代码缓存 11-24 的写入"; find /tmp/torchinductor_root -newermt "2026-11-24 00:00" -type f -printf "%TH:%TM %s %p\n" 2>/dev/null | sort | tail -8; echo "total: $(find /tmp/torchinductor_root -type f 2>/dev/null | wc -l)"'
D 'echo "-- 相关超时默认值"; V=/usr/local/lib/python3.12/site-packages/vllm; grep -nE "dequeue_timeout|VLLM_RPC_TIMEOUT|VLLM_ENGINE|DISTRIBUTED_TIMEOUT" $V/v1/executor/multiproc_executor.py $V/envs.py 2>/dev/null | head -12; grep -rnE "timedelta\(minutes=10\)|timedelta\(seconds=600\)|timeout=600" $V/distributed/*.py $V/v1/executor/*.py 2>/dev/null | head -8'
PROBE_EOF
  sed -i "s#RUNLOG#$RUN/logs/server.log#g" "$PROBE"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE" 2>&1 | head -220

  echo "== 1. 本地待同步文件（来自 145 仓库 clone）=="
  md5sum "$SRC_MOCK" "$SRC_TOOL/vllmBench_lite_base_mock_py312.sh" \
         "$SRC_TOOL/vllmBench_lite_base_mock.sh"

  echo "== 2. 145 部署目录 / 198 容器当前版本 =="
  md5sum "$HOST_TOOL/vllmBench_lite_base_mock_py312.sh" "$HOST_TOOL/vllmBench_lite_base_mock.sh"
  ssh "$REMOTE" "docker exec -i vllm bash -lc 'md5sum $DOCKER_MOCK; md5sum $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh $DOCKER_TOOL/vllmBench_lite_base_mock.sh'"

  for f in "$SRC_MOCK" "$SRC_TOOL/vllmBench_lite_base_mock_py312.sh" "$SRC_TOOL/vllmBench_lite_base_mock.sh"; do
    [[ -f "$f" ]] || { echo "ERROR: 缺少 $f（先在仓库 clone 里 git pull）"; exit 3; }
  done

  if [[ "$FIX" != 1 ]]; then
    echo "== 3. 预览（未写入；执行 FIX=1 bash cmd.sh 才会同步）=="
    echo "将覆盖：$HOST_TOOL/vllmBench_lite_base_mock{,_py312}.sh"
    echo "        $DOCKER_MOCK"
    echo "        $DOCKER_TOOL/vllmBench_lite_base_mock{,_py312}.sh"
  else
    echo "== 3. 备份 =="
    cp -f "$HOST_TOOL/vllmBench_lite_base_mock_py312.sh" "$HOST_TOOL/vllmBench_lite_base_mock_py312.sh.bak-20261124b"
    cp -f "$HOST_TOOL/vllmBench_lite_base_mock.sh" "$HOST_TOOL/vllmBench_lite_base_mock.sh.bak-20261124b"
    ssh "$REMOTE" "docker exec -i vllm bash -lc '
      cp -f $DOCKER_MOCK $DOCKER_MOCK.bak-20261124b &&
      cp -f $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh.bak-20261124b &&
      cp -f $DOCKER_TOOL/vllmBench_lite_base_mock.sh $DOCKER_TOOL/vllmBench_lite_base_mock.sh.bak-20261124b &&
      ls -l $DOCKER_MOCK.bak-20261124b $DOCKER_TOOL/*.bak-20261124b'"

    echo "== 4. 同步到 145 部署目录 =="
    cp -f "$SRC_TOOL/vllmBench_lite_base_mock_py312.sh" "$HOST_TOOL/vllmBench_lite_base_mock_py312.sh"
    cp -f "$SRC_TOOL/vllmBench_lite_base_mock.sh" "$HOST_TOOL/vllmBench_lite_base_mock.sh"
    chmod +x "$HOST_TOOL"/vllmBench_lite_base_mock{,_py312}.sh

    echo "== 5. 写入 198 容器 =="
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'cat > $DOCKER_MOCK'" < "$SRC_MOCK"
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'cat > $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh'" < "$SRC_TOOL/vllmBench_lite_base_mock_py312.sh"
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'cat > $DOCKER_TOOL/vllmBench_lite_base_mock.sh'" < "$SRC_TOOL/vllmBench_lite_base_mock.sh"

    echo "== 6. 校验（应与第 1 节一致）=="
    md5sum "$HOST_TOOL/vllmBench_lite_base_mock_py312.sh" "$HOST_TOOL/vllmBench_lite_base_mock.sh"
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'chmod +x $DOCKER_TOOL/vllmBench_lite_base_mock*.sh; md5sum $DOCKER_MOCK $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh $DOCKER_TOOL/vllmBench_lite_base_mock.sh; bash -n $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh && bash -n $DOCKER_TOOL/vllmBench_lite_base_mock.sh && echo SCRIPT_OK'"
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'grep -n \"MOCK_STACK_DUMP:-1\|STALL_ABORT_SECONDS\" $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh | head -4'"
  fi

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
