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
