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
  # 第十一批：只读拉取两个 bench 脚本全文与差异，为去掉 PGO 切换逻辑做准备。

  CON=corex5-py311
  D=/home/huawei_ts_program/litehost_perf_opt

  docker exec "$CON" sh -c "
D=$D
echo '== 1. 目录下的 bench 脚本 =='
ls -la --time-style=long-iso \$D/*.sh 2>/dev/null

echo '== 2. base 脚本全文 =='
nl -ba \$D/vllmBench_lite_base.sh

echo '== 3. opt 脚本全文 =='
nl -ba \$D/vllmBench_lite_opt.sh

echo '== 4. 两脚本差异 =='
diff -u \$D/vllmBench_lite_base.sh \$D/vllmBench_lite_opt.sh | head -200

echo '== 5. PGO/rebase 关键行 =='
grep -nE 'PGO|pgo|rebase|PREFIX|PYTHON_BIN' \$D/vllmBench_lite_base.sh \$D/vllmBench_lite_opt.sh | head -80
"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
