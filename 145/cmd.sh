#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：① 只读查证 100823 期间是否有别的进程在同一 VM 编译/抢 CPU；② FIX=1 时同步新 mock+脚本（先备份）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
FIX="${FIX:-0}"
PROBE=/tmp/probe198h.sh

SRC_MOCK=/home/qch/mock_vllm/mock_gpu/worker_patch.py
SRC_TOOL=/home/huawei_ts_program/litehost_perf_opt
DOCKER_MOCK=/home/qch/mock_vllm/mock_gpu/worker_patch.py
DOCKER_TOOL=/home/huawei_ts_program/litehost_perf_opt

{
  echo "### server: 145 -> 198  (FIX=$FIX)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  echo "== 0. 100823 期间是否另有编译/进程在抢资源（只读）=="
  cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
ssh_into() { docker exec -i vllm bash -lc "$1"; }
for CMD in \
  'echo "-- 部署脚本里的 TORCHINDUCTOR_CACHE_DIR"; grep -n TORCHINDUCTOR /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base_mock_py312.sh | head -5' \
  'echo "-- default_cache_dir() 是否吃环境变量"; TORCHINDUCTOR_CACHE_DIR=/probe_marker /usr/local/bin/python3 -c "from torch._inductor import codecache as c; print(c.default_cache_dir())" 2>&1 | tail -2' \
  'echo "-- 固定 cache 下的 PCH"; ls -ld --time-style=long-iso /home/huawei_ts_program/inductor_cache_py312/precompiled_headers 2>&1; find /home/huawei_ts_program/inductor_cache_py312/precompiled_headers -name "*.gch" -printf "%TY-%Tm-%Td %TH:%TM %s\n" 2>/dev/null | sort | tail -3' \
  'echo "-- /tmp 下的 PCH"; ls -ld --time-style=long-iso /tmp/torchinductor_root/precompiled_headers 2>&1; find /tmp/torchinductor_root/precompiled_headers -name "*.gch" -printf "%TY-%Tm-%Td %TH:%TM %s\n" 2>/dev/null | sort | tail -3' \
  'echo "-- 各 run 的 server.log 时间范围"; VB=/home/huawei_ts_program/litehost_perf_opt/vllmBench; for D in $VB/*/; do L=${D}logs/server.log; [ -f "$L" ] || continue; printf "%-45s %s  %s .. %s\n" "$(basename "$D")" "$(stat -c %y "$L" | cut -c1-16)" "$(grep -oE "[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" "$L" | head -1)" "$(grep -oE "[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" "$L" | tail -1)"; done | sort -k2' \
  'echo "-- 100823 的 config 与瓶颈行"; R=/home/huawei_ts_program/litehost_perf_opt/vllmBench/py312_litehost_gap_20261124_100823; grep -E "mock_env|TORCHINDUCTOR|inductor_cache" "$R"/config.txt 2>&1 | head -5; grep -oE "11:(1[0-9]|2[0-9]):[0-9]{2} .{0,90}" "$R"/logs/server.log | tail -12' \
  'echo "-- /tmp 的 perf map 与编译残留"; ls -la --time-style=long-iso /tmp/perf-*.map 2>&1 | head -15' \
  'echo "-- 当前仍在跑的 python/编译进程"; ps -eo pid,etime,pcpu,args | grep -E "python|cc1plus|ninja|g\+\+" | grep -v grep | head -15' \
  ; do ssh_into "$CMD" 2>&1 | sed 's/^Authorized users only.*//'; done
PROBE_EOF
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE" 2>&1 | head -120

  echo "== 1. 本地待同步文件 =="
  md5sum "$SRC_MOCK" "$SRC_TOOL/vllmBench_lite_base_mock_py312.sh" \
         "$SRC_TOOL/vllmBench_lite_base_mock.sh"

  echo "== 2. 198 当前版本 =="
  ssh "$REMOTE" "docker exec -i vllm bash -lc 'md5sum $DOCKER_MOCK; md5sum $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh $DOCKER_TOOL/vllmBench_lite_base_mock.sh'"

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
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'chmod +x $DOCKER_TOOL/vllmBench_lite_base_mock*.sh; md5sum $DOCKER_MOCK $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh $DOCKER_TOOL/vllmBench_lite_base_mock.sh; bash -n $DOCKER_TOOL/vllmBench_lite_base_mock_py312.sh && bash -n $DOCKER_TOOL/vllmBench_lite_base_mock.sh && echo SCRIPT_OK'"

    echo "== 6. mock 版本号（下次运行日志里应看到新 id）=="
    ssh "$REMOTE" "docker exec -i vllm bash -lc 'cd /tmp && PYTHONPATH=/home/qch/mock_vllm /usr/local/bin/python3 -c \"import mock_gpu.autoload as m; print(m.VERSION_ID)\"'"
  fi

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
