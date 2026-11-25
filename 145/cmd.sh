#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：**写入**（非只读）。把 py312/py311 两个 bench 脚本和 mock 的
#       worker_patch.py 同步到 198 的 vllm 容器：先备份、再逐字节校验。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
CT=vllm
TOOLKIT=/home/huawei_ts_program/litehost_perf_opt
MOCK=/home/qch/mock_vllm/mock_gpu
BK=/home/qch/deploy_backup_$TS
A="$TOOLKIT/vllmBench_lite_base_mock_py312.sh"
B="$TOOLKIT/vllmBench_lite_base_mock.sh"
C="$MOCK/worker_patch.py"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE")
D() { "${SSH[@]}" "docker exec $CT bash -lc '$1'" 2>&1 | sed '/^Authorized users only/d'; }

# push <本地文件> <容器内目标路径>：base64 过 ssh 管道，容器里解码后原子替换
push() {
  base64 < "$1" | "${SSH[@]}" \
    "docker exec -i $CT bash -c 'base64 -d > $2.new && chmod 755 $2.new && mv $2.new $2'" 2>&1 \
    | sed '/^Authorized users only/d'
  local rc=${PIPESTATUS[1]}
  echo "push rc=$rc  $(basename "$1") -> $2"
  return "$rc"
}

VID() {
  D "python3 -c \"import hashlib,pathlib; h=hashlib.sha1(); [h.update(p.name.encode()) or h.update(p.read_bytes()) for p in sorted(pathlib.Path('$MOCK').glob('*.py'))]; print('$1', h.hexdigest()[:10])\""
}

{
  echo "### server: 145 -> 198 vllm 容器  (写入)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### backup: $BK"
  echo
  set -x

  echo "== 0. 本地待部署文件 =="
  md5sum "$ROOT/litehost_toolkit/vllmBench_lite_base_mock_py312.sh" \
         "$ROOT/litehost_toolkit/vllmBench_lite_base_mock.sh" \
         "$ROOT/mock_vllm/mock_gpu/worker_patch.py"

  echo "== 1. 远端现状（只读）=="
  PRE=$(D "for f in $A $B $C; do test -f \$f && echo \"ok \$f\" || echo \"MISSING \$f\"; done
           md5sum $A $B $C 2>/dev/null; python3 -V")
  echo "$PRE"
  VID "mock_VERSION_ID(before)="

  echo "== 2. 备份 =="
  if echo "$PRE" | grep -q '^MISSING'; then
    echo "!! 目标文件缺失，停止部署"
  else
    D "mkdir -p $BK && cp -a $A $B $C $BK/ && ls -l $BK"

    echo "== 3. 推送 =="
    push "$ROOT/litehost_toolkit/vllmBench_lite_base_mock_py312.sh" "$A"
    push "$ROOT/litehost_toolkit/vllmBench_lite_base_mock.sh" "$B"
    push "$ROOT/mock_vllm/mock_gpu/worker_patch.py" "$C"

    echo "== 4. 远端校验 =="
    D "md5sum $A $B $C
       bash -n $A && echo SYNTAX_OK_py312
       bash -n $B && echo SYNTAX_OK_py311
       python3 -c \"import py_compile; py_compile.compile('$C', doraise=True); print('PY_OK')\""
    VID "mock_VERSION_ID(after)="
    D "echo '-- 关键行'; grep -n 'host_tag\\|PYTHONFAULTHANDLER' $A | head -6
       grep -n 'faulthandler' $C | head -4"

    echo "== 5. 本地/远端 md5 比对 =="
    L=$(md5sum "$ROOT/litehost_toolkit/vllmBench_lite_base_mock_py312.sh" \
                "$ROOT/litehost_toolkit/vllmBench_lite_base_mock.sh" \
                "$ROOT/mock_vllm/mock_gpu/worker_patch.py" | awk '{print $1}')
    R=$(D "md5sum $A $B $C" | awk '{print $1}')
    if [ "$L" = "$R" ]; then echo "MD5_MATCH"; else echo "MD5_MISMATCH"; echo "local: $L"; echo "remote: $R"; fi
  fi

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
