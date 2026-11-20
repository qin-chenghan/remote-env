#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。定位“不显式传 MODEL_PATH 仍失败”的真正来源。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

C=vllm
TOOLS=/home/huawei_ts_program/litehost_perf_opt

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  echo "== 1. 容器环境里是否已设置 MODEL_PATH =="
  docker exec vllm bash -lc 'echo "bash -lc  : MODEL_PATH=[${MODEL_PATH:-<unset>}]"'
  docker exec vllm bash -c 'echo "bash -c   : MODEL_PATH=[${MODEL_PATH:-<unset>}]"'
  docker inspect vllm --format '{{json .Config.Env}}' | tr ',' '\n' | grep -i "MODEL" | head -3 || echo "Config.Env 无 MODEL_PATH"

  echo "== 2. profile 里有没有导出 =="
  docker exec vllm bash -lc 'grep -rn "MODEL_PATH" /etc/profile /etc/profile.d/*.sh /etc/bash.bashrc /root/.bashrc /root/.profile 2>/dev/null | head -6 || echo "profile 无 MODEL_PATH"'

  echo "== 3. 实际运行的那份脚本里的默认值（容器内）=="
  docker exec vllm bash -lc "grep -n 'MODEL_PATH=' $TOOLS/vllmBench_lite_base_mock_py312.sh | head -3"

  echo "== 4. 宿主那份（对照，可能你改的是这里）=="
  grep -n "MODEL_PATH=" "$TOOLS"/vllmBench_lite_base_mock_py312.sh 2>/dev/null | head -3

  echo "== 5. 两个模型路径在容器里是否存在 =="
  docker exec vllm bash -lc '
    for p in /home/model/Qwen3-32B-W8A8 /home/model/ts/Qwen3-32B-W8A8; do
      if [ -d "$p" ]; then echo "$p EXISTS $(du -sh $p 2>/dev/null | cut -f1)"; else echo "$p MISSING"; fi
    done'

  echo "== 6. 最近一次失败的 run 里用的模型路径 =="
  docker exec vllm bash -lc '
    d=$(ls -dt /home/huawei_ts_program/litehost_perf_opt/vllmBench/*/ 2>/dev/null | head -1)
    echo "latest: $d"
    grep -m2 -E "model=|MODEL_PATH" "$d/config.txt" "$d/logs/server.log" 2>/dev/null | head -6
  ' 2>&1 | head -10

  echo "== 7. harness 里 MODEL_PATH 的用法（确认是否是 env 优先）=="
  docker exec vllm bash -lc "grep -n 'MODEL_PATH' $TOOLS/vllmBench_lite_base_mock_py312.sh | head -6"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
