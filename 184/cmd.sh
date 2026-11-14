#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 给 vllmBench_lite_opt.sh 打开 r14 的 compact_greedy，并移除两个无效 env（备份 + 语法检查 + diff）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  S=/home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh
  BAK="$S.bak-compact-$TS"

  echo "== 1. 占用检查 =="
  ps -eo pid,args 2>/dev/null | grep -E 'vllm|bench_driver|vllmBench_lite' | grep -v grep | head -5 || echo "无相关进程"

  echo "== 2. 备份 =="
  cp -a "$S" "$BAK" && ls -l "$BAK"

  echo "== 3. 修改 =="
  python3 - "$S" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read()
old_cfg='--enable_chunked_prefill --compilation-config \'{"cudagraph_mode":"FULL_DECODE_ONLY", "mode":0, "sample_logits_cudagraph":"on", "sample_logits_cudagraph_max_bytes":67108864, "sample_logits_cudagraph_capture_sizes":[1,2,3,4,5,6,7,8]}\''
new_cfg='--enable_chunked_prefill --compilation-config \'{"cudagraph_mode":"FULL_DECODE_ONLY", "mode":0, "compact_greedy":true, "sample_logits_cudagraph":"on", "sample_logits_cudagraph_max_bytes":67108864, "sample_logits_cudagraph_capture_sizes":[1,2,3,4,5,6,7,8]}\''
old_env='    VLLM_COMPACT_GREEDY=on\n    VLLM_COMPACT_GREEDY_DIAGNOSTICS=0\n'
changes=[]
if 'compact_greedy' in s and '"compact_greedy":true' in s:
    changes.append('compact_greedy 已存在，跳过')
elif old_cfg in s:
    s=s.replace(old_cfg,new_cfg,1); changes.append('compilation-config 已加入 compact_greedy')
else:
    changes.append('CFG_PATTERN_NOT_FOUND')
if old_env in s:
    s=s.replace(old_env,'',1); changes.append('已移除两个无效 env')
else:
    changes.append('ENV_PATTERN_NOT_FOUND')
if 'CFG_PATTERN_NOT_FOUND' in changes or 'ENV_PATTERN_NOT_FOUND' in changes:
    print(changes, '未写入'); sys.exit(3)
open(p,'w').write(s)
print(changes)
PY
  echo "patch rc=$?"

  echo "== 4. 语法检查与 diff =="
  bash -n "$S" && echo "bash -n OK"
  diff -u "$BAK" "$S" | head -40

  echo "== 5. 确认关键行 =="
  grep -n 'compilation-config' "$S"
  grep -n 'VLLM_COMPACT_GREEDY\|VLLM_HOST_OPT_METADATA\|VLLM_HOST_OPT=' "$S"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
