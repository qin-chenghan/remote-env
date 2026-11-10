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
  # 基线冒烟：不注入 LD_PRELOAD、不开 fastpath，默认参数起 vLLM，发一个请求，再关掉。

  echo "== 1. 模型路径 =="
  MODEL=/home/models/Qwen3-32B-W8A8
  echo "MODEL=$MODEL"
  ls "$MODEL" 2>&1 | head -10
  if [ -z "$MODEL" ]; then
    echo "!! 未找到模型，停止"
    exit 0
  fi
  du -sh "$MODEL" 2>/dev/null

  echo "== 2. 启动基线 vLLM（端口 8899）=="
  docker exec corex5-py311 pkill -f 'vllm.entrypoints.openai.api_server' 2>/dev/null
  sleep 2
  docker exec -d corex5-py311 bash -c "
    cd /tmp && env -u LD_PRELOAD -u VLLM_HOST_FASTPATH -u TORCH_MODULE_ATTR_FASTPATH \
      XDG_CACHE_HOME=/tmp/cache \
      /opt/corex311/bin/python -m vllm.entrypoints.openai.api_server \
      --host 127.0.0.1 --port 8899 --model $MODEL \
      --trust_remote_code --dtype auto --max-model-len 4096 \
      --tensor-parallel-size 4 --gpu-memory-utilization 0.9 \
      > /tmp/vllm_base.log 2>&1
  "
  echo "launched rc=$?"

  echo "== 3. 等待就绪（最多 8 分钟）=="
  OK=0
  for i in $(seq 1 96); do
    CODE=$(docker exec corex5-py311 /opt/corex311/bin/python -c "
import urllib.request
try:
    print(urllib.request.urlopen('http://127.0.0.1:8899/health', timeout=2).status)
except Exception:
    print('x')
" 2>/dev/null)
    if [ "$CODE" = "200" ]; then OK=1; echo "ready after ${i}0s"; break; fi
    if [ $((i % 6)) -eq 0 ]; then echo "waiting ${i}0s..."; fi
    sleep 10
  done
  echo "ready=$OK"

  if [ "$OK" = "1" ]; then
    echo "== 4. 发一个请求 =="
    docker exec corex5-py311 /opt/corex311/bin/python -c "
import json,urllib.request,time
body={'model':'$MODEL','prompt':'Hello, what is 1+1?','max_tokens':32,'temperature':0}
req=urllib.request.Request('http://127.0.0.1:8899/v1/completions',
    data=json.dumps(body).encode(), headers={'Content-Type':'application/json'})
t=time.time(); r=json.load(urllib.request.urlopen(req, timeout=120))
print('latency_s', round(time.time()-t,2))
print('text', r['choices'][0]['text'][:200])
print('usage', r['usage'])
" 2>&1 | tail -8
   else
    echo "!! 未就绪，看日志"
  fi

  echo "== 5. 服务日志尾部 =="
  docker exec corex5-py311 bash -c 'tail -40 /tmp/vllm_base.log' 2>&1 | head -45

  echo "== 6. 关闭 =="
  docker exec corex5-py311 pkill -f 'vllm.entrypoints.openai.api_server' 2>/dev/null
  sleep 3
  docker exec corex5-py311 bash -c 'pgrep -af vllm | head -5 || echo "no vllm left"' 2>&1
  timeout 20 /usr/local/corex-5.0.0/bin/ixsmi 2>&1 | grep -E 'Memory-Usage|MiB /' | head -6

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
