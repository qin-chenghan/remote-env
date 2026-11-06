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
  # 重建干净 PGO venv 前的只读准备：只关心“怎样才能装出和 base 一样的包集合”。
  # 不删除、不安装、不建 venv。

  CON=corex5-py311
  BASE=/opt/corex311
  NEW=/opt/corex311-cpython-vllm
  BUNDLE=/home/z30059427/corex5-py311-20261009

  echo "== 1. install_corex311.sh 全文 =="
  docker exec "$CON" sh -c "cat $BUNDLE/install_corex311.sh"

  echo "== 2. README（离线安装/来源相关）=="
  docker exec "$CON" sh -c "sed -n '1,160p' $BUNDLE/README.md"

  echo "== 3. hashed 清单与 base 已装包集合是否对应 =="
  docker exec -i -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" - <<'PY'
import re, subprocess, sys

REQ = "/home/z30059427/corex5-py311-20261009/requirements-all.hashed.txt"

def parse_req(path):
    d = {}
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if " --hash=" in line:
            line = line.split(" --hash=", 1)[0].strip()
        m = re.match(r"^([A-Za-z0-9_.\-]+)==([^\s;]+)", line)
        if m:
            d[m.group(1).lower()] = m.group(2)
        elif " @ " in line:
            name = line.split(" @ ", 1)[0].strip().lower()
            d[name] = "url"
    return d

freeze = subprocess.run([sys.executable, "-m", "pip", "freeze", "--all"],
                        capture_output=True, text=True).stdout
inst = {}
for line in freeze.splitlines():
    line = line.strip()
    if not line or line.startswith("#") or line.startswith("-e "):
        continue
    if "==" in line:
        n, v = line.split("==", 1)
        inst[n.lower()] = v
req = parse_req(REQ)

skip = {"pip", "setuptools", "wheel"}
only_req = sorted(k for k in set(req) - set(inst))
only_inst = sorted(k for k in set(inst) - set(req) - skip)
mismatch = sorted(k for k in set(req) & set(inst) if req[k] != inst[k])
print(f"requirements={len(req)} installed={len(inst)} covered={len(set(req) & set(inst)) - len(mismatch)}")
print(f"in_requirements_not_installed={len(only_req)}")
print(f"installed_not_in_requirements(excl pip/setuptools/wheel)={len(only_inst)}")
print(f"version_mismatch={len(mismatch)}")
print("--- in requirements, not installed ---")
for k in only_req:
    print(f"{k}=={req[k]}")
print("--- installed, not in requirements ---")
for k in only_inst:
    print(f"{k}=={inst[k]}")
print("--- version mismatch ---")
for k in mismatch:
    print(f"{k} | req {req[k]} -> inst {inst[k]}")
PY

  echo "== 4. vendor 目录与 wheel 来源 =="
  docker exec "$CON" sh -c "
ls -la $BUNDLE/vendor
echo '-- 安装脚本里与来源相关的行 --'
grep -nE 'find-links|no-index|index-url|pip download|wheelhouse|vendor|network|offline' $BUNDLE/install_corex311.sh $BUNDLE/README.md | head -40
echo '-- 机器上的 wheelhouse --'
find /home/z30059427 -maxdepth 4 -type d -iname '*wheelhouse*' 2>/dev/null | head -10
"

  echo "== 5. verify_corex311.py 用法 =="
  docker exec "$CON" sh -c "sed -n '1,80p' $BUNDLE/verify_corex311.py"

  echo "== 6. 新 venv 占用/磁盘 =="
  docker exec "$CON" sh -c "
for p in /proc/[0-9]*; do
  e=\$(readlink \"\$p/exe\" 2>/dev/null) || continue
  case \"\$e\" in *corex311-cpython-vllm*) echo \"\${p#/proc/} \$e\";; esac
done | head -10
du -sh $NEW 2>/dev/null
df -h /opt | tail -1
"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
