#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读。评估能否在 145 上部署 vLLM 无卡 mock（需要 python3.11 + torch + vLLM + 模型）。
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

  echo "== 1. 机器与容量 =="
  uname -a
  nproc; lscpu | grep -E "Model name|Socket|Core|Thread|NUMA|Architecture" | head -10
  free -g | head -2
  df -h / /home 2>/dev/null | tail -2
  echo "-- 容器 --"
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1 | head -6

  echo "== 2. 宿主机 python 与包 =="
  command -v python3.11 python3 python3.9 2>&1
  for p in python3.11 python3; do
    if command -v $p >/dev/null 2>&1; then
      echo "-- $p: $($p -V 2>&1)"
      $p -m pip list 2>/dev/null | grep -iE "^(torch|triton|vllm|numpy|transformers|safetensors|pillow|ray)\b" | head -12
      echo "   (以上为空则未装 torch/vllm)"
    fi
  done

  echo "== 3. 容器内 python 与包 =="
  docker exec fusionv1 bash -lc '
python3 -V 2>&1
ls /usr/bin/python* /usr/local/bin/python* 2>/dev/null | head -6
echo "-- pip --"
command -v pip pip3 2>&1 | head -2
python3 -m pip list 2>/dev/null | grep -iE "^(torch|triton|vllm|numpy|transformers|pillow)\b" | head -12
echo "-- /opt --"
ls /opt 2>/dev/null | head -10
' 2>&1 | head -30

  echo "== 4. 是否已有 vLLM / torch 安装痕迹 =="
  ls -d /opt/corex311 /opt/corex311-cpython-vllm /opt/python-3.11.6 2>&1
  ls -l /home/model /home/model/ts 2>&1 | head -8
  ls -l /home/huawei_ts_program 2>&1 | head -5
  grep -rIl "import vllm" /home/qch --include=*.py 2>/dev/null | head -5

  echo "== 5. 能否联网拉 aarch64 wheel（只解析，不安装）=="
  timeout 20 python3.11 - <<'PY' 2>&1 | tail -5
import urllib.request
for url in ("https://pypi.org/simple/torch/", "https://mirrors.aliyun.com/pypi/simple/torch/"):
    try:
        r = urllib.request.urlopen(url, timeout=8)
        print(url, "OK", r.status)
    except Exception as e:
        print(url, "FAIL", type(e).__name__, e)
PY

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
