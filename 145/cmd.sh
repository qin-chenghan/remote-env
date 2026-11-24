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
D 'echo "-- 三份 gch 是否相同（同 .h + 同编译命令 => 相同）"; H=/tmp/torchinductor_root/precompiled_headers; md5sum $H/*.h.gch 2>&1'
D 'echo "-- PCH 键在源码里怎么算的"; T=$(/usr/local/bin/python3 -c "import torch,os;print(os.path.dirname(torch.__file__))"); grep -n "precompiled" $T/_inductor/codecache.py $T/_inductor/cpp_builder.py 2>/dev/null | head -30'
D 'echo "-- 当前环境算出的 PCH 路径（和上面三个文件名比）"; TORCHINDUCTOR_CACHE_DIR=/home/huawei_ts_program/inductor_cache_py312 /usr/local/bin/python3 -c "import torch,torch._inductor.codecache as c;ns=[n for n in dir(c) if \"precompiled\" in n.lower()];print(\"attrs:\",ns);[print(n,\"->\",getattr(c,n)()) for n in ns if callable(getattr(c,n))]" 2>&1 | tail -12'
D 'echo "-- 环境现状"; uptime; getconf _NPROCESSORS_ONLN; grep -m1 -oE "asimd|sve|bf16|crc32|sha3" /proc/cpuinfo | sort -u; env | grep -E "^TORCHINDUCTOR|^VLLM" | sort'
PROBE_EOF
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
