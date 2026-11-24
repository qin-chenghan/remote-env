#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：① 只读对比三次运行的启动时长；② FIX=1 时把新版 mock/脚本同步到 198（先备份）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
FIX="${FIX:-0}"
PROBE=/tmp/probe198g.sh

SRC_MOCK=/home/qch/mock_vllm/mock_gpu/worker_patch.py
SRC_TOOL=/home/huawei_ts_program/litehost_perf_opt
DOCKER_MOCK=/home/qch/mock_vllm/mock_gpu/worker_patch.py
DOCKER_TOOL=/home/huawei_ts_program/litehost_perf_opt

{
  echo "### server: 145 -> 198  (FIX=$FIX)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  echo "== 0. 启动时长对比（只读）=="
  cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
VB=/home/huawei_ts_program/litehost_perf_opt/vllmBench
docker exec -i vllm bash -lc '
VB=/home/huawei_ts_program/litehost_perf_opt/vllmBench
for D in py312_litehost_gap_20261123_155113 py312_litehost_gap_20261123_155940 py312_litehost_gap_20261124_100823; do
  L=$VB/$D/logs/server.log
  echo "---- $D"
  echo -n "first: "; grep -oE "[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" $L | head -1
  echo -n "last:  "; grep -oE "[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" $L | tail -1
  grep -oE "[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \[[a-z_]+\.py:[0-9]+\] (Loading weights took|Graph capturing finished|Application startup complete)" $L | head -4
done'
PROBE_EOF
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE" 2>&1 | head -40

  echo "== 1. 本地待同步文件 =="
  md5sum "$SRC_MOCK" "$SRC_TOOL/vllmBench_lite_base_mock_py312.sh" \
         "$SRC_TOOL/vllmBench_lite_base_mock.sh"

  echo "== 2. 198 当前版本 =="
  ssh "$REMOTE" "docker exec -i vllm bash -lc 'md5sum $DOCKER_MOCK; grep -c MOCK_TP_CPUS_DEFER $DOCKER_MOCK; md5sum $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh'"

  if [[ "$FIX" != 1 ]]; then
    echo "== 3. 预览（未写入；执行 FIX=1 bash cmd.sh 才会同步）=="
    echo "将覆盖：$DOCKER_MOCK"
    echo "        $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh"
    echo "        $DOCKER_TOOL/vllmBench_lite_base_mock.sh"
  else
    echo "== 3. 备份现有文件 =="
    ssh "$REMOTE" "docker exec -i vllm bash -lc '
      cp -f $DOCKER_MOCK $DOCKER_MOCK.bak-20261124 &&
      cp -f $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh.bak-20261124 &&
      cp -f $DOCKER_TOOL/vllmBench_lite_base_mock.sh $DOCKER_TOOL/vllmBench_lite_base_mock.sh.bak-20261124 &&
      ls -l $DOCKER_MOCK.bak-20261124 $DOCKER_TOOL/*.bak-20261124'"

    echo "== 4. 写入 =="
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'cat > $DOCKER_MOCK'" < "$SRC_MOCK"
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'cat > $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh'" < "$SRC_TOOL/vllmBench_lite_base_mock_py312.sh"
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'cat > $DOCKER_TOOL/vllmBench_lite_base_mock.sh'" < "$SRC_TOOL/vllmBench_lite_base_mock.sh"

    echo "== 5. 校验（应与第 1 节一致）=="
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'chmod +x $DOCKER_TOOL/vllmBench_lite_base_mock*.sh; md5sum $DOCKER_MOCK $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh $DOCKER_TOOL/vllmBench_lite_base_mock.sh; bash -n $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh && echo SCRIPT_OK'"

    echo "== 6. mock 版本号（下次运行日志里应看到新 id）=="
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'cd /tmp && PYTHONPATH=/home/qch/mock_vllm /usr/local/bin/python3 -c \"import mock_gpu.autoload as m; print(m.VERSION_ID)\"'"
  fi

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
