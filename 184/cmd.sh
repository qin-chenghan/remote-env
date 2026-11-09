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
  # 第十批 B：卸 9 个多余厂商包 + 装 torch_module_attr_fastpath + 严格 parity。
  # 只动 /opt/corex311-cpython-vllm；/opt/corex311 只读。

  CON=corex5-py311
  BASE=/opt/corex311
  V=/opt/corex311-cpython-vllm
  FW=/home/qch/transfer/torch_module_attr_fastpath-0.1.0.dev2-cp311-cp311-linux_aarch64.whl
  FW_SHA=9eb6ca36702600d85b754f21e4b812394ead6c09c17dcba1cd007776a84f573b
  TRIM="cupy cupy-cuda11x cupy-cuda12x flash-attn pynvml ray torchaudio torchvision torchdebug"

  source /home/qch/env/set_proxy.sh 2>/dev/null || true
  PX=()
  [ -n "${http_proxy:-}" ] && PX+=(-e "http_proxy=$http_proxy")
  [ -n "${https_proxy:-}" ] && PX+=(-e "https_proxy=$https_proxy")
  [ -n "${no_proxy:-}" ] && PX+=(-e "no_proxy=$no_proxy")

  echo "== 0. 前置检查 =="
  docker exec "$CON" sh -c "test -d $V && echo 'target exists' || echo 'target missing'"
  USE=$(docker exec "$CON" sh -c 'for p in /proc/[0-9]*; do e=$(readlink "$p/exe" 2>/dev/null) || continue; case "$e" in *corex311-cpython-vllm*) echo "$e";; esac; done' | head -3)
  if [ -n "$USE" ]; then
    echo "ABORT: 目标 venv 正被进程使用"; echo "$USE"; exit 1
  fi
  echo "无进程占用"

  echo "== 1. 卸掉 9 个 base 没有的厂商包 =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -m pip uninstall -y $TRIM 2>&1 | tail -15

  echo "== 2. 工具链复核（应已与 base 一致）=="
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -m pip --version
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -c \
    "import importlib.metadata as m; print('setuptools', m.version('setuptools')); print('wheel', m.version('wheel'))" 2>&1 | tail -3

  echo "== 3. 装 torch_module_attr_fastpath =="
  FWSHA=$(docker exec "$CON" sh -c "sha256sum $FW 2>/dev/null | cut -d' ' -f1")
  echo "wheel sha256: $FWSHA"
  if [ "$FWSHA" != "$FW_SHA" ]; then
    echo "WARN: 摘要不符（期望 $FW_SHA），跳过安装"
  else
    docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -m pip install --no-index --no-deps "$FW" 2>&1 | tail -6
  fi

  echo "== 4. pip check =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -m pip check || true

  echo "== 5. 严格 parity（importlib.metadata 真实版本，绕开 freeze 渲染）=="
  docker exec -i -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" - <<'PY'
import json, os, re, subprocess

norm = lambda n: re.sub(r"[-_.]+", "-", n.strip().lower())

DUMP = (
    "import importlib.metadata as m, json\n"
    "d = {}\n"
    "for dist in m.distributions():\n"
    "    try:\n"
    "        n = dist.metadata['Name']\n"
    "        v = dist.version\n"
    "    except Exception:\n"
    "        continue\n"
    "    if n and v:\n"
    "        d[n] = v\n"
    "print(json.dumps(d))\n"
)

def dump(interp):
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "PYTHONHOME")}
    r = subprocess.run([interp, "-c", DUMP], capture_output=True, text=True, env=env)
    if r.returncode != 0:
        print(interp, "ERROR", r.stderr[-400:])
        return {}
    return json.loads(r.stdout.strip().splitlines()[-1])

base = {norm(k): v for k, v in dump("/opt/corex311/bin/python").items()}
new = {norm(k): v for k, v in dump("/opt/corex311-cpython-vllm/bin/python").items()}
print(f"base datasets={len(base)} new datasets={len(new)}")
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
    print("PARITY PASS: 包集合与版本完全一致")
else:
    print("PARITY FAIL")
PY

  echo "== 6. 最终状态 =="
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -c \
    'import sys,sysconfig; print("prefix", sys.prefix); print("base_prefix", sys.base_prefix)'
  docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -c \
    'import vllm, torch; print("vllm", vllm.__version__); print("torch", torch.__version__)' 2>&1 | tail -3
  docker exec "$CON" sh -c "du -sh $V $BASE 2>/dev/null; df -h /opt | tail -1"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
