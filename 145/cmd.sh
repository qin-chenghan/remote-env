#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：把 bench 脚本的 WARMUP_ONLY 预热模式同步到 145 部署目录和 198 容器（FIX=1 才写）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
FIX="${FIX:-0}"
BAK=.bak-20261124c
PROBE_SH=/tmp/probe198w.sh

SRC_MOCK=/home/qch/mock_vllm/mock_gpu/worker_patch.py
SRC_TOOL=/home/qch/tools/remote-env/litehost_toolkit          # 145 上的仓库 clone（git pull 后即最新）
HOST_TOOL=/home/huawei_ts_program/litehost_perf_opt            # 145 上实际运行的部署目录
DOCKER_MOCK=/home/qch/mock_vllm/mock_gpu/worker_patch.py
DOCKER_TOOL=/home/huawei_ts_program/litehost_perf_opt

{
  echo "### server: 145 -> 198  (FIX=$FIX)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  echo "== 0. 198 上 test-warmup/2 两次预热的实际结果（只读）=="
  cat > "$PROBE_SH" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
D() { docker exec vllm bash -lc "$1" 2>&1 | sed '/^Authorized users only/d'; }
B=/home/huawei_ts_program/litehost_perf_opt/vllmBench
D 'echo "-- 两个 run 目录"; ls -la --time-style=long-iso /home/huawei_ts_program/litehost_perf_opt/vllmBench/test-warmup /home/huawei_ts_program/litehost_perf_opt/vllmBench/test-warmup2 2>&1 | head -30'
for r in test-warmup test-warmup2; do
  D "echo \"-- $r config.txt\"; cat $B/$r/config.txt 2>&1"
  D "echo \"-- $r 目录与日志\"; ls -la $B/$r $B/$r/logs 2>&1 | head -20"
  D "echo \"-- $r 关键阶段\"; L=$B/$r/logs/server.log; wc -l \$L 2>&1; grep -nE 'activated|pinned to cpu|Capturing CUDA graphs|Starting|EngineCore|ompil' \$L 2>/dev/null | tail -20"
  D "echo \"-- $r 报错与结尾\"; L=$B/$r/logs/server.log; grep -nE 'ERROR|Error|Traceback|RuntimeError|raise |failed|FATAL|停滞|取消|cancelled' \$L 2>/dev/null | tail -25; echo '--- tail ---'; tail -n 45 \$L 2>&1"
done
D 'echo "-- test-warmup 根因：worker 自己的栈"; L=/home/huawei_ts_program/litehost_perf_opt/vllmBench/test-warmup/logs/server.log; grep -nE "litehost|LIGHTHOST|session|Connection|connect|Permission|No such file|AttributeError|ImportError|OSError|abort|Abort|signal" \$L 2>/dev/null | head -40'
D 'echo "-- test-warmup server.log 140-300 行"; sed -n "140,300p" /home/huawei_ts_program/litehost_perf_opt/vllmBench/test-warmup/logs/server.log'
D 'echo "-- PCH 头文件（有没有今天 16:4x 之后的新增）"; ls -la --time-style=long-iso /tmp/torchinductor_root/precompiled_headers/*.h 2>&1'
D 'echo "-- 16:40 之后的内核缓存写入"; find /home/huawei_ts_program/inductor_cache_py312 -newermt "2026-11-24 16:40" -printf "%TH:%TM:%TS %p\n" 2>/dev/null | sort | head -20'
PROBE_EOF
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE_SH" 2>&1 | head -420

  echo "== 1. 待同步文件（来自 145 仓库 clone）=="
  md5sum "$SRC_MOCK" "$SRC_TOOL/vllmBench_lite_base_mock_py312.sh" \
         "$SRC_TOOL/vllmBench_lite_base_mock.sh"

  echo "== 2. 当前部署版本（145 目录 / 198 容器）=="
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
    cp -f "$HOST_TOOL/vllmBench_lite_base_mock_py312.sh" "$HOST_TOOL/vllmBench_lite_base_mock_py312.sh$BAK"
    cp -f "$HOST_TOOL/vllmBench_lite_base_mock.sh" "$HOST_TOOL/vllmBench_lite_base_mock.sh$BAK"
    ssh "$REMOTE" "docker exec -i vllm bash -lc '
      cp -f $DOCKER_MOCK $DOCKER_MOCK$BAK &&
      cp -f $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh$BAK &&
      cp -f $DOCKER_TOOL/vllmBench_lite_base_mock.sh $DOCKER_TOOL/vllmBench_lite_base_mock.sh$BAK &&
      ls -l $DOCKER_MOCK$BAK $DOCKER_TOOL/*$BAK'"

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
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'grep -n \"WARMUP_ONLY\" $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh | head -5'"
  fi

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
