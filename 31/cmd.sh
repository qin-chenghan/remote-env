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
  echo "### 本轮只读：了解 31 的沐曦（MetaX）环境。"
  echo "###           采集系统 / PCI / mx-smi / 驱动 / MACA / 容器 / 模型；"
  echo "###           不装包、不改配置、不启动服务。"
  set +x

  echo
  echo "== 0. 系统 =="
  date
  uname -a
  head -6 /etc/os-release 2>/dev/null || true
  echo "arch=$(uname -m) nproc=$(nproc)"
  lscpu 2>/dev/null | grep -E '^(Model name|Socket|Core|NUMA node|CPU\(s\))' | head -10 || true
  free -h 2>/dev/null | head -3 || true
  df -h / /home /data 2>/dev/null | tail -n +1 | head -10 || true

  echo
  echo "== 1. 加速卡（PCI / 设备节点） =="
  echo "-- lspci（沐曦 vendor 1f24；加速卡 class 1200/0380） --"
  lspci -nn 2>/dev/null | grep -iE '1f24|metax|muxi|processing accelerators|3d controller|display' \
      || echo "lspci 未见加速卡"
  echo "-- 设备节点 --"
  ls -l /dev/mx* /dev/metax* /dev/dri 2>/dev/null || true
  ls /proc/driver 2>/dev/null || true

  echo
  echo "== 2. mx-smi =="
  if command -v mx-smi >/dev/null 2>&1; then
      echo "path=$(command -v mx-smi)"
      timeout 20 mx-smi --version 2>&1 || true
      echo "-- mx-smi -L --"
      timeout 20 mx-smi -L 2>&1 || true
      echo "-- mx-smi --"
      timeout 30 mx-smi 2>&1 | head -80 || true
      echo "-- mx-smi -q（截前 120 行） --"
      timeout 30 mx-smi -q 2>&1 | head -120 || true
  else
      echo "!! PATH 中没有 mx-smi"
      ls -l /opt/maca*/bin/mx-smi /usr/local/maca*/bin/mx-smi /usr/bin/mx-smi 2>/dev/null || true
  fi

  echo
  echo "== 3. 驱动 / 内核模块 =="
  echo "kernel=$(uname -r)"
  lsmod 2>/dev/null | grep -iE 'metax|maca|^mx' || echo "lsmod 未见 metax/mx 模块"
  dkms status 2>/dev/null | head -10 || true
  ls -d /lib/modules/"$(uname -r)"/kernel/drivers/*/*mx* 2>/dev/null || true

  echo
  echo "== 4. MACA 软件栈 =="
  ls -d /opt/maca* /opt/mxdriver* /usr/local/maca* 2>/dev/null || true
  env | grep -iE '^(MACA|MX|METAX)[A-Z0-9_]*=' | sort || true
  for py in python3 /opt/maca*/bin/python3; do
      [ -x "$py" ] || continue
      echo "-- $py: $("$py" --version 2>&1)"
      "$py" - <<'PY' 2>/dev/null || true
import importlib
for m in ("torch", "vllm", "transformers"):
    try:
        mod = importlib.import_module(m)
        print(f"  {m}={getattr(mod, '__version__', '?')}")
    except Exception as e:
        print(f"  {m}=未安装 ({type(e).__name__})")
PY
  done

  echo
  echo "== 5. 容器 / 镜像 =="
  if command -v docker >/dev/null 2>&1; then
      echo "docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
      echo "-- docker ps -a --"
      docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null | head -30 || true
      echo "-- 相关镜像（metax/maca/vllm/torch/qwen） --"
      docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.ID}}' 2>/dev/null \
          | grep -iE 'metax|maca|vllm|torch|qwen|pytorch' | head -30 || true
      echo "-- runtimes --"
      docker info --format '{{.Runtimes}}' 2>/dev/null || true
  else
      echo "无 docker"
  fi

  echo
  echo "== 6. 模型 / 工作目录 =="
  ls -d /home/* /data/* 2>/dev/null | head -30 || true
  find /home /data -maxdepth 3 -type d \
      \( -iname 'qwen*' -o -iname 'bert*' -o -iname '*mmoe*' \) 2>/dev/null | head -30 || true
  ls -l /home/model 2>/dev/null | head -20 || true

  echo
  echo "== 7. 运行时状态 =="
  pgrep -af 'vllm.entrypoints.openai.api_server' | grep -v pgrep || echo "无 vllm 服务"
  ss -ltn 2>/dev/null | head -20 || true

  echo
  echo "### 采集结束（本轮只读）"
  # ---- 命令结束 ----
} 2>&1 | tee "$OUT"

rc=${PIPESTATUS[0]}
echo
echo "### exit: $rc"
echo "### log: $OUT"
exit "$rc"
