#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
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
  # 隔离 184 上旧 metadata 补丁的残留：先查引用，有引用就中止。
  # 只 mv 到 /opt/_trash_*，不 rm。不动其他文件，不动服务。

  CON=corex5-py311
  SP=/opt/corex311/lib/python3.11/site-packages
  TRASH="/opt/_trash_$(date +%Y%m%d-%H%M%S)"

  echo "== 0. 清理前指纹 =="
  docker exec "$CON" sh -c "
SP=$SP
sha256sum \$SP/vllm/v1/worker/gpu_model_runner.py \
          \$SP/vllm/v1/worker/host_fastpath.py \
          \$SP/vllm/v1/attention/backends/ilu_flash_attn.py \
          \$SP/vllm/envs.py \
          \$SP/vllm/_host_opt_native.abi3.so \
          \$SP/vllm/_host_opt_meta_native.cpython-311-aarch64-linux-gnu.so \
          \$SP/vllm/v1/sample/sampler.py \
          \$SP/vllm/model_executor/layers/logits_processor.py 2>/dev/null
" > /tmp/184_pre_hash.txt
  cat /tmp/184_pre_hash.txt

  echo "== 1. 引用检查（命中则中止，退出码 2）=="
  docker exec "$CON" sh -c '
SP=/opt/corex311/lib/python3.11/site-packages
FOUND=0
for D in /home/huawei_ts_program/litehost_perf_opt /home/qch/scripts "$SP/vllm"; do
  [ -d "$D" ] || continue
  HIT=$(grep -rnE "metadata_optimization|native_input_metadata|native_spec_metadata|vllm\.iluvatar\.input_pipeline|from vllm\.iluvatar import input_pipeline" "$D" \
        --include="*.py" --include="*.sh" 2>/dev/null \
        | grep -vE "iluvatar/(metadata_optimization|native_input_metadata|native_spec_metadata|input_pipeline)\.py:")
  if [ -n "$HIT" ]; then
    echo "REFERENCES in $D:"
    echo "$HIT" | head -20
    FOUND=1
  fi
done
if [ "$FOUND" -eq 1 ]; then
  echo "ABORT: references found, nothing moved."
  exit 2
fi
echo "no references"
exit 0
'
  REF=$?
  if [ "$REF" -eq 2 ]; then
    echo "== 中止：存在引用，未做任何移动 =="
  else
    echo "== 2. 隔离残留到 $TRASH =="
    docker exec -e TRASH="$TRASH" "$CON" sh -c '
SP=/opt/corex311/lib/python3.11/site-packages
mkdir -p "$TRASH/iluvatar_orphans"
if [ -d "$SP/vllm/.corex_metadata_patch" ]; then
  mv "$SP/vllm/.corex_metadata_patch" "$TRASH/"
  echo "moved .corex_metadata_patch"
else
  echo ".corex_metadata_patch not present"
fi
for n in metadata_optimization native_input_metadata native_spec_metadata input_pipeline; do
  if [ -f "$SP/vllm/iluvatar/$n.py" ]; then
    mv "$SP/vllm/iluvatar/$n.py" "$TRASH/iluvatar_orphans/"
    echo "moved $n.py"
  fi
  for p in "$SP/vllm/iluvatar/__pycache__/$n".*.pyc; do
    [ -f "$p" ] && { mv "$p" "$TRASH/iluvatar_orphans/"; echo "moved $(basename "$p")"; }
  done
done
echo "-- 隔离目录内容 --"
find "$TRASH" -maxdepth 5 -type f -printf "%10s %p\n" 2>/dev/null | sort -k2
'

    echo "== 3. 残留复查 =="
    docker exec "$CON" sh -c '
SP=/opt/corex311/lib/python3.11/site-packages
echo "-- iluvatar 目录 --"
ls -la --time-style=long-iso $SP/vllm/iluvatar/ 2>/dev/null
echo "-- 是否还有旧补丁文件 --"
for n in metadata_optimization native_input_metadata native_spec_metadata input_pipeline; do
  [ -f "$SP/vllm/iluvatar/$n.py" ] && echo "STILL PRESENT $n.py" || echo "gone $n.py"
done
[ -d "$SP/vllm/.corex_metadata_patch" ] && echo "STILL PRESENT .corex_metadata_patch" || echo "gone .corex_metadata_patch"
'

    echo "== 4. import 冒烟 =="
    docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" /opt/corex311/bin/python -c "
import vllm
from vllm.v1.worker import host_fastpath
print('import ok', vllm.__version__, host_fastpath.HostFastPath.__name__)
" 2>&1 | tail -5

    echo "== 5. 清理后指纹对比 =="
    docker exec "$CON" sh -c "
SP=$SP
sha256sum \$SP/vllm/v1/worker/gpu_model_runner.py \
          \$SP/vllm/v1/worker/host_fastpath.py \
          \$SP/vllm/v1/attention/backends/ilu_flash_attn.py \
          \$SP/vllm/envs.py \
          \$SP/vllm/_host_opt_native.abi3.so \
          \$SP/vllm/_host_opt_meta_native.cpython-311-aarch64-linux-gnu.so \
          \$SP/vllm/v1/sample/sampler.py \
          \$SP/vllm/model_executor/layers/logits_processor.py 2>/dev/null
" > /tmp/184_post_hash.txt
    if diff -u /tmp/184_pre_hash.txt /tmp/184_post_hash.txt; then
      echo "OK: 关键文件指纹未变"
    else
      echo "WARN: 指纹发生变化，请检查"
    fi
  fi

  echo "== 恢复方法（如需回滚）=="
  echo "  docker exec $CON mv $TRASH/iluvatar_orphans/*.py  $SP/vllm/iluvatar/"
  echo "  docker exec $CON mv $TRASH/.corex_metadata_patch    $SP/vllm/"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
