#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：**写入**（非只读）。部署两个 bench 脚本：准备阶段不绑核、就绪后
#       taskset 绑核；harness 输出落盘；启动前 import 预检。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
CT=vllm
TOOLKIT=/home/huawei_ts_program/litehost_perf_opt
BK=/home/qch/deploy_backup_$TS
A="$TOOLKIT/vllmBench_lite_base_mock_py312.sh"
B="$TOOLKIT/vllmBench_lite_base_mock.sh"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE")
D() { printf '%s\n' "$1" | "${SSH[@]}" "docker exec -i $CT bash -s" 2>&1 | sed '/^Authorized users only/d'; }

push() {
  base64 < "$1" | "${SSH[@]}" \
    "docker exec -i $CT bash -c 'base64 -d > $2.new && chmod 755 $2.new && mv $2.new $2'" 2>&1 \
    | sed '/^Authorized users only/d'
  local rc=${PIPESTATUS[1]}
  echo "push rc=$rc  $(basename "$1") -> $2"
  return "$rc"
}

{
  echo "### server: 145 -> 198 vllm 容器  (写入)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### backup: $BK"
  echo
  set -x

  echo "== 0. 本地 md5 =="
  md5sum "$ROOT/litehost_toolkit/vllmBench_lite_base_mock_py312.sh" \
         "$ROOT/litehost_toolkit/vllmBench_lite_base_mock.sh"

  echo "== 1. 远端现状 =="
  PRE=$(D "for f in $A $B; do test -f \$f && echo \"ok \$f\" || echo \"MISSING \$f\"; done
            md5sum $A $B 2>/dev/null
            command -v taskset timeout")
  echo "$PRE"

  if echo "$PRE" | grep -q '^MISSING'; then
    echo "!! 目标文件缺失，停止部署"
  else
    echo "== 2. 备份 =="
    D "mkdir -p $BK && cp -a $A $B $BK/ && ls -l $BK"

    echo "== 3. 推送 =="
    push "$ROOT/litehost_toolkit/vllmBench_lite_base_mock_py312.sh" "$A"
    push "$ROOT/litehost_toolkit/vllmBench_lite_base_mock.sh" "$B"

    echo "== 4. 远端校验 =="
    D "md5sum $A $B
       bash -n $A && echo SYNTAX_OK_py312
       bash -n $B && echo SYNTAX_OK_py311
       echo '-- 关键行'
       grep -n 'pin_workers_runtime\\|preflight_import\\|harness.log\\|MOCK_TP_CPUS= MOCK_TP_CPUS_DEFER=0' $A | head -8"

    echo "== 5. md5 比对 =="
    L=$(md5sum "$ROOT/litehost_toolkit/vllmBench_lite_base_mock_py312.sh" \
                "$ROOT/litehost_toolkit/vllmBench_lite_base_mock.sh" | awk 'NF{print $1}')
    R=$(D "md5sum $A $B" | awk 'NF{print $1}')
    if [ "$L" = "$R" ]; then echo "MD5_MATCH"; else echo "MD5_MISMATCH"; echo "local: $L"; echo "remote: $R"; fi
  fi

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
