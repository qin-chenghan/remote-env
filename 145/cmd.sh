#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：在 vllm 容器里安装 shell 启动文件，使 LD_LIBRARY_PATH 自动生效（不重建容器）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

LIB=/usr/local/corex/lib64:/usr/local/openmpi/lib:/usr/local/lib

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 安装 /etc/profile.d/corex-path.sh（登录 shell）=="
  docker exec vllm bash -c "printf '%s\n' \
    '# added for corex runtime libs' \
    'export LD_LIBRARY_PATH=$LIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}' \
    > /etc/profile.d/corex-path.sh"
  docker exec vllm bash -c 'cat /etc/profile.d/corex-path.sh'

  echo "== 2. 追加到 /etc/bash.bashrc（交互式非登录 shell，幂等）=="
  docker exec vllm bash -c "
    if ! grep -q corex-path /etc/bash.bashrc 2>/dev/null; then
      printf '%s\n' '' '. /etc/profile.d/corex-path.sh  # corex-path' >> /etc/bash.bashrc
      echo added
    else
      echo already-present
    fi"
  docker exec vllm bash -c 'tail -3 /etc/bash.bashrc'

  echo "== 3. 两种进入方式验证 =="
  echo "-- 登录 shell（脚本用 bash -lc）"
  docker exec vllm bash -lc 'echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"'
  echo "-- 交互式 shell（docker exec -it bash）"
  docker exec vllm bash -ic 'echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"' 2>/dev/null

  echo "== 4. 实际效果：登录 shell 里 import torch / mock =="
  docker exec vllm bash -lc \
    'PYTHONPATH=/home/qch/mock_vllm /opt/corex311/bin/python3 -c "import torch; import mock_gpu.autoload"' 2>&1 | tail -4

  echo "== 5. 直接 exec 二进制（不经过 shell）仍无环境，属预期 =="
  docker exec vllm /opt/corex311/bin/python3 -c 'import torch' 2>&1 | tail -2

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
