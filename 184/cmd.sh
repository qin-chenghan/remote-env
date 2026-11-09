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
  # 第十批：正式重建 /opt/corex311-cpython-vllm。
  # 只动该目录；/opt/corex311 不动。步骤失败即停，不自动回滚，末尾给回滚命令。

  CON=corex5-py311
  BASE=/opt/corex311
  V=/opt/corex311-cpython-vllm
  B=/home/z30059427/corex5-py311-20261009
  PY=/opt/cpython-vllm/v1/bin/python3.11
  FW=/home/qch/transfer/torch_module_attr_fastpath-0.1.0.dev2-cp311-cp311-linux_aarch64.whl
  FW_SHA=9eb6ca36702600d85b754f21e4b812394ead6c09c17dcba1cd007776a84f573b
  TRIM="cupy cupy-cuda11x cupy-cuda12x flash-attn pynvml ray torchaudio torchvision torchdebug"

  source /home/qch/env/set_proxy.sh 2>/dev/null || true
  PX=()
  [ -n "${http_proxy:-}" ] && PX+=(-e "http_proxy=$http_proxy")
  [ -n "${https_proxy:-}" ] && PX+=(-e "https_proxy=$https_proxy")
  [ -n "${no_proxy:-}" ] && PX+=(-e "no_proxy=$no_proxy")

  echo "== 0. 前置检查 =="
  echo -n "目标存在: "; docker exec "$CON" sh -c "test -d $V && echo yes || echo no"
  docker exec "$CON" sh -c "du -sh $V 2>/dev/null || true"
  USE=$(docker exec "$CON" sh -c 'for p in /proc/[0-9]*; do e=$(readlink "$p/exe" 2>/dev/null) || continue; case "$e" in *corex311-cpython-vllm*) echo "$e";; esac; done' | head -3)
  if [ -n "$USE" ]; then
    echo "ABORT: 目标 venv 正被进程使用:"
    echo "$USE"
    exit 1
  fi
  echo "无进程占用"
  echo -n "api_server 是否在跑: "
  docker exec "$CON" sh -c 'pgrep -f vllm.entrypoints.openai.api_server >/dev/null && echo "yes (注意 CPU 占用)" || echo no'

  echo "== 1. 隔离旧 venv =="
  TRASH="/opt/_trash_$(date +%Y%m%d-%H%M%S)"
  docker exec "$CON" sh -c "mkdir -p $TRASH && mv $V $TRASH/corex311-cpython-vllm-old && ls -la $TRASH && echo '隔离完成: $TRASH'"

  echo "== 2. 官方 installer 建 venv 并安装 =="
  docker exec "${PX[@]}" -e PYTHONPATH= -e PYTHONHOME= -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$CON" bash "$B/install_corex311.sh" "$PY" "$V" 2>&1 | tail -40
  RC=${PIPESTATUS[0]}
  if [ "$RC" -ne 0 ]; then
    echo "INSTALL FAILED rc=$RC"
    echo "回滚: docker exec $CON sh -c 'rm -rf $V && mv $TRASH/corex311-cpython-vllm-old $V'"
    exit 1
  fi

  echo "== 3. 卸掉 base 没有的 9 个厂商包 =="
  docker exec "${PX[@]}" -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -m pip uninstall -y $TRIM 2>&1 | tail -15

  echo "== 4. 工具链对齐 base =="
  docker exec "${PX[@]}" -e PYTHONPATH= -e PYTHONHOME= -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$CON" "$V/bin/python" -m pip install --upgrade pip==25.3 setuptools==80.9.0 wheel==0.45.1 2>&1 | tail -8

  echo "== 5. 装 torch_module_attr_fastpath =="
  echo -n "wheel sha256: "; docker exec "$CON" sh -c "sha256sum $FW 2>/dev/null | cut -d' ' -f1"
  FWSHA=$(docker exec "$CON" sh -c "sha256sum $FW 2>/dev/null | cut -d' ' -f1")
  if [ "$FWSHA" != "$FW_SHA" ]; then
    echo "WARN: fastpath wheel 摘要不符（期望 $FW_SHA），跳过安装"
  else
    docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -m pip install --no-index --no-deps "$FW" 2>&1 | tail -6
  fi

  echo "== 6. pip check =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -m pip check || true

  echo "== 7. 解释器与导入检查 =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -c \
    'import sys,sysconfig; print("prefix", sys.prefix); print("base_prefix", sys.base_prefix); print("CONFIG_ARGS", sysconfig.get_config_var("CONFIG_ARGS"))'
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -c \
    'import vllm, torch; print("vllm", vllm.__version__, vllm.__file__); print("torch", torch.__version__, torch.__file__)' 2>&1 | tail -6

  echo "== 8. 包集合对比 base vs new（归一化）=="
  docker exec -i -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" - <<'PY'
import os, re, subprocess

norm = lambda n: re.sub(r"[-_.]+", "-", n.strip().lower())

def freeze(interp):
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "PYTHONHOME")}
    env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    out = subprocess.run([interp, "-m", "pip", "freeze", "--all"],
                         capture_output=True, text=True, env=env).stdout
    d = {}
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("-e "):
            continue
        if " @ " in line:
            d[norm(line.split(" @ ", 1)[0])] = "(url)"
        elif "==" in line:
            n, v = line.split("==", 1)
            d[norm(n)] = v.strip()
        else:
            d[norm(line)] = "(bare)"
    return d

base = freeze("/opt/corex311/bin/python")
new = freeze("/opt/corex311-cpython-vllm/bin/python")
print(f"base={len(base)} new={len(new)}")
only_base = sorted(set(base) - set(new))
only_new = sorted(set(new) - set(base))
mism = sorted(k for k in set(base) & set(new) if base[k] != new[k])
print(f"only_base={len(only_base)} only_new={len(only_new)} mismatch={len(mism)}")
for k in only_base:
    print(f"  ONLY_BASE {k}=={base[k]}")
for k in only_new:
    print(f"  ONLY_NEW  {k}=={new[k]}")
for k in mism:
    print(f"  MISMATCH  {k} | base {base[k]} -> new {new[k]}")
if not only_base and not only_new and not mism:
    print("PARITY PASS: 包集合完全一致")
PY

  echo "== 9. 磁盘与结论 =="
  docker exec "$CON" sh -c "du -sh $V $BASE 2>/dev/null; df -h /opt | tail -1"
  echo "旧 venv 隔离在: $TRASH"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
