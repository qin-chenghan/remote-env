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
  # 第七批：重建干净 PGO venv 的最后准备，全部只读。
  # A. 修正版包集合对比（名称归一化 + @ 行解析）
  # B. 普通依赖来源：bundle wheels / pip 源 / wheelhouse / 网络
  # C. base 的 pip 工具版本
  # 不删除、不安装、不建 venv。

  CON=corex5-py311
  BASE=/opt/corex311
  BUNDLE=/home/z30059427/corex5-py311-20261009

  echo "== A. 修正版包集合对比 =="
  docker exec -i -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" - <<'PY'
import re, subprocess, sys

B = "/home/z30059427/corex5-py311-20261009"
norm = lambda n: re.sub(r"[-_.]+", "-", n.strip().lower())

def parse_req(path):
    d = {}
    for raw in open(path):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        line = re.split(r"\s+--hash", line)[0].strip()
        if " @ " in line:
            d[norm(line.split(" @ ", 1)[0])] = "(url)"
        else:
            m = re.match(r"([A-Za-z0-9_.\-]+)(?:\[[^\]]*\])?==([^\s;]+)", line)
            if m:
                d[norm(m.group(1))] = m.group(2)
    return d

def parse_freeze(text):
    d = {}
    for line in text.splitlines():
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

freeze = subprocess.run([sys.executable, "-m", "pip", "freeze", "--all"],
                        capture_output=True, text=True).stdout
inst = parse_freeze(freeze)
print(f"base installed (normalized) = {len(inst)}")

for fname in ("requirements-all.hashed.txt", "requirements-py311.txt", "requirements-vendor-py311.txt"):
    req = parse_req(f"{B}/{fname}")
    miss = sorted(set(req) - set(inst))
    extra = sorted(set(inst) - set(req))
    mism = sorted(k for k in set(req) & set(inst) if req[k] != inst[k] and req[k] != "(url)")
    print(f"\n===== {fname}: req={len(req)} covered={len(set(req) & set(inst)) - len(mism)} "
          f"missing={len(miss)} mismatch={len(mism)} base_extra={len(extra)}")
    if miss:
        print("-- 需求有、base 没有 --")
        for k in miss:
            print(f"  {k}=={req[k]}")
    if mism:
        print("-- 版本不一致 --")
        for k in mism:
            print(f"  {k} | req {req[k]} -> base {inst[k]}")
    if extra:
        print("-- base 有、需求没有 --")
        for k in extra:
            print(f"  {k}=={inst[k]}")
PY

  echo "== B. 普通依赖来源 =="
  docker exec "$CON" sh -c "
B=$BUNDLE
echo '-- \$BUNDLE/wheels 是否存在 --'
ls -la \"\$B/wheels\" 2>/dev/null || echo 'no wheels dir'
echo '-- bundle 根目录 --'
ls -la \"\$B\" | head -20
echo '-- pip 配置文件 --'
for f in /etc/pip.conf /root/.pip/pip.conf /root/.config/pip/pip.conf /opt/corex311/pip.conf; do
  [ -f \"\$f\" ] && { echo \"== \$f\"; cat \"\$f\"; }
done
echo '-- 环境变量 --'
env | grep -iE 'PIP_|INDEX_URL' || echo none
echo '-- pip config list --'
/opt/corex311/bin/python -m pip config list 2>&1 | head -10
echo '-- wheelhouse --'
ls -la /home/z30059427/wheelhouse 2>/dev/null | head -25
find /home/z30059427/wheelhouse -maxdepth 1 -name '*.whl' 2>/dev/null | wc -l
find /home/z30059427/wheelhouse -maxdepth 1 -name 'transformers*.whl' -o -maxdepth 1 -name 'numpy*.whl' 2>/dev/null | head -5
echo '-- 网络探测（只读）--'
timeout 8 getent hosts pypi.org || echo 'dns pypi.org failed'
timeout 8 curl -sI https://pypi.org/simple/ 2>&1 | head -3 || echo 'curl failed'
"

  echo "== C. base 的 pip 工具版本 =="
  docker exec "$CON" sh -c "
/opt/corex311/bin/python -m pip --version
/opt/corex311/bin/python -c 'import setuptools, wheel; print(\"setuptools\", setuptools.__version__); print(\"wheel\", wheel.__version__)' 2>/dev/null || echo 'wheel not importable'
/opt/corex311/bin/python -c 'import sys; print(sys.version)'
"

  echo "== D. 新 venv 是否仍无占用 =="
  docker exec "$CON" sh -c "
for p in /proc/[0-9]*; do
  e=\$(readlink \"\$p/exe\" 2>/dev/null) || continue
  case \"\$e\" in *corex311-cpython-vllm*) echo \"\${p#/proc/} \$e\";; esac
done | head -10
echo "(空 = 无进程使用)"
"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
