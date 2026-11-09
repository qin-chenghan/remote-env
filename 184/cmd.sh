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
  # 第八批：重建前的联网可行性探测，只读 + 只发 GET/--dry-run，不装包。
  # A. 代理脚本与网络模式
  # B. constraints 文件
  # C. 容器内无代理 / 带代理探测
  # D. pip --dry-run 端到端探测
  # E. base 自身工具链版本、确认 9 个厂商包未装

  CON=corex5-py311
  BASE=/opt/corex311

  echo "== A. 代理脚本与网络模式 =="
  if [ -f /home/qch/env/set_proxy.sh ]; then
    echo "-- set_proxy.sh 内容 --"
    cat /home/qch/env/set_proxy.sh
    # shellcheck disable=SC1091
    source /home/qch/env/set_proxy.sh || true
    echo "-- source 后的代理变量 --"
    env | grep -iE 'proxy' || echo "no proxy vars after source"
  else
    echo "missing /home/qch/env/set_proxy.sh"
  fi
  echo "-- 容器 network mode --"
  docker inspect "$CON" --format '{{.HostConfig.NetworkMode}}'
  echo "-- 容器现有代理变量 --"
  docker exec "$CON" sh -c 'env | grep -iE "proxy" || echo "container has no proxy vars"' || true

  PX=()
  [ -n "${http_proxy:-}" ] && PX+=(-e "http_proxy=$http_proxy")
  [ -n "${https_proxy:-}" ] && PX+=(-e "https_proxy=$https_proxy")
  [ -n "${HTTP_PROXY:-}" ] && PX+=(-e "HTTP_PROXY=$HTTP_PROXY")
  [ -n "${HTTPS_PROXY:-}" ] && PX+=(-e "HTTPS_PROXY=$HTTPS_PROXY")
  [ -n "${no_proxy:-}" ] && PX+=(-e "no_proxy=$no_proxy")
  echo "-- 将传入容器的代理参数 --"
  printf '%s\n' "${PX[@]:-<none>}"

  echo "== B. PIP_CONSTRAINT 文件 =="
  docker exec "$CON" sh -c '
echo "-- /opt/pip/constraints.txt --"
if [ -f /opt/pip/constraints.txt ]; then
  wc -l /opt/pip/constraints.txt
  sed -n "1,80p" /opt/pip/constraints.txt
else
  echo "missing"
fi
echo "-- 其他 constraints --"
ls -la /opt/pip 2>/dev/null | head -10
'

  echo "== C1. 容器内无代理探测 =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" - <<'PY' || true
import urllib.request
url = "https://mirrors.aliyun.com/pypi/simple/six/"
try:
    with urllib.request.urlopen(url, timeout=12) as r:
        body = r.read(200)
    print("OK HTTP", r.status, "first-bytes", len(body))
except Exception as e:
    print("FAIL", type(e).__name__, str(e)[:120])
PY

  echo "== C2. 容器内带代理探测 =="
  docker exec "${PX[@]}" -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" - <<'PY' || true
import os, urllib.request
print("proxy env:", {k: v for k, v in os.environ.items() if "proxy" in k.lower()})
url = "https://mirrors.aliyun.com/pypi/simple/six/"
try:
    with urllib.request.urlopen(url, timeout=12) as r:
        body = r.read(200)
    print("OK HTTP", r.status, "first-bytes", len(body))
except Exception as e:
    print("FAIL", type(e).__name__, str(e)[:120])
PY

  echo "== D. pip --dry-run 端到端探测（不安装、不写缓存）=="
  docker exec "${PX[@]}" -e PYTHONPATH= -e PYTHONHOME= -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$CON" "$BASE/bin/python" -m pip install --dry-run --no-cache-dir \
    --only-binary=:all: six==1.17.0 2>&1 | tail -10 || true

  echo "== E1. base 自身工具链版本（清 PYTHONPATH）=="
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" -m pip --version || true
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" -c \
    "import setuptools, wheel; print('setuptools', setuptools.__version__); print('wheel', wheel.__version__)" 2>&1 | tail -4 || true

  echo "== E2. 确认 9 个厂商包未安装 =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" -m pip show \
    ray flash-attn cupy cupy-cuda11x cupy-cuda12x pynvml torchaudio torchvision torchdebug 2>&1 | tail -6 || true

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
