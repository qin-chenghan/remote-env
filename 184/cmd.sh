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
  # 第三批：仍然严格只读。不删除、不安装、不建 venv、不动服务。
  # A. /opt 全量盘点与“是否被使用”的证据
  # B. 上批未执行的：包集合漂移量化、host fastpath 模块定位、bundle/补丁来源

  CON=corex5-py311
  BASE=/opt/corex311
  NEW=/opt/corex311-cpython-vllm

  echo "== 1. /opt 顶层内容与时间 =="
  docker exec "$CON" sh -c 'ls -la --time-style=long-iso /opt'
  echo "-- 各目录大小（timeout 180）--"
  timeout 180 docker exec "$CON" sh -c 'du -sh /opt/* 2>/dev/null | sort -h'
  docker exec "$CON" sh -c 'df -h /opt | tail -1'

  echo "== 2. /opt 下所有 venv 清单（pyvenv.cfg 为准）=="
  timeout 180 docker exec "$CON" sh -c '
find /opt -maxdepth 3 -name pyvenv.cfg -print 2>/dev/null | while IFS= read -r cfg; do
  V=$(dirname "$cfg")
  echo "---- $V"
  ls -ld --time-style=long-iso "$V"
  du -sh "$V" 2>/dev/null
  grep -E "^(home|version|executable|command|include-system)" "$cfg"
  echo -n "  bin/python -> "; readlink "$V/bin/python" 2>/dev/null || echo missing
  if [ -x "$V/bin/python" ]; then
    PYTHONPATH= PYTHONHOME= timeout 20 "$V/bin/python" -c "import sys;print(\"  prefix\",sys.prefix);print(\"  base\",sys.base_prefix)" 2>&1 | tail -2
  else
    echo "  bin/python missing or not executable"
  fi
  echo -n "  bin entries: "; ls "$V/bin" 2>/dev/null | wc -l
done
'

  echo "== 3. 是否有进程正在使用 /opt 下的解释器（容器内视角）=="
  docker exec "$CON" sh -c '
echo "-- ps 中的 /opt/*/bin/python --"
ps -eo pid,args 2>/dev/null | grep -E "/opt/[^ ]*/bin/python" | grep -v grep | head -20
echo "-- /proc/*/exe 指向 /opt 的进程 --"
for p in /proc/[0-9]*; do
  e=$(readlink "$p/exe" 2>/dev/null) || continue
  case "$e" in /opt/*) echo "${p#/proc/} $e";; esac
done | head -30
echo "-- 进程环境里的 VIRTUAL_ENV --"
for p in /proc/[0-9]*; do
  ve=$(tr "\0" "\n" < "$p/environ" 2>/dev/null | sed -n "s/^VIRTUAL_ENV=//p")
  [ -n "$ve" ] && echo "${p#/proc/} $ve"
done | sort -u -k2 | head -20
'

  echo "== 4. 脚本/配置里对 /opt/corex311* 的引用 =="
  timeout 90 docker exec "$CON" sh -c '
for D in /home/qch/scripts /home/qch/tools /home/huawei_ts_program/litehost_perf_opt /home/huawei_ts_program; do
  [ -d "$D" ] || continue
  echo "-- $D --"
  grep -RIn --include="*.sh" --include="*.py" --include="*.json" --include="*.txt" "/opt/corex311" "$D" 2>/dev/null | grep -v "/site-packages/" | head -25
done
'

  echo "== 5. 容器与挂载关系（判断 /opt 是否容器独有）=="
  docker ps --format '{{.Names}}	{{.Image}}	{{.Status}}'
  docker inspect "$CON" --format '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}{{println}}{{end}}'
  docker exec "$CON" sh -c 'findmnt -T /opt -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || mount | grep " /opt "'

  echo "== 6. 包集合漂移量化（复用上轮 /tmp 文件，不存在则重建）=="
  if [ ! -f /tmp/freeze-base.txt ] || [ ! -f /tmp/freeze-new.txt ]; then
    docker exec -e PYTHONPATH= -e PYTHONHOME= -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
      "$CON" "$BASE/bin/python" -m pip freeze --all 2>/dev/null | sort > /tmp/freeze-base.txt
    docker exec -e PYTHONPATH= -e PYTHONHOME= -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
      "$CON" "$NEW/bin/python" -m pip freeze --all 2>/dev/null | sort > /tmp/freeze-new.txt
  fi
  python3 - <<'PY'
def parse(path):
    d = {}
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        if '==' in line and ' @ ' not in line:
            name = line.split('==', 1)[0]
        elif ' @ ' in line:
            name = line.split(' @ ', 1)[0]
        else:
            name = line
        d[name.lower()] = line
    return d

base = parse('/tmp/freeze-base.txt')
new = parse('/tmp/freeze-new.txt')
only_base = sorted(set(base) - set(new))
only_new = sorted(set(new) - set(base))
mismatch = sorted(n for n in set(base) & set(new) if base[n] != new[n])

print(f"base={len(base)} new={len(new)} same={len(set(base)&set(new)) - len(mismatch)} "
      f"version_mismatch={len(mismatch)} only_base={len(only_base)} only_new={len(only_new)}")
print("--- 版本不同（name | base -> new）---")
for n in mismatch:
    b = base[n]
    m = new[n]
    if ' @ ' in b or ' @ ' in m:
        b = b[:110] + ('...' if len(b) > 110 else '')
        m = m[:110] + ('...' if len(m) > 110 else '')
    else:
        b = b.split('==', 1)[-1]
        m = m.split('==', 1)[-1]
    print(f"{n} | {b} -> {m}")
print("--- 只在 base（新 venv 缺）---")
for n in only_base:
    print(base[n])
print("--- 只在 new（base 没有）---")
for n in only_new:
    print(new[n])
PY

  echo "== 7. host fastpath 模块的真实位置（find_spec）=="
  for V in "$BASE" "$NEW"; do
    echo "-- $V --"
    timeout 120 docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -c '
import importlib.util as u
for m in ("vllm.v1.worker.host_fastpath",
          "vllm.v1.worker.corex_host_opt",
          "corex_host_opt",
          "corex_host_native",
          "corex_host_native.inputs",
          "corex_host_native.bookkeeping",
          "corex_host_native.metadata"):
    try:
        s = u.find_spec(m)
    except Exception as e:
        print(f"{m:45s} ERR {type(e).__name__}: {e}")
        continue
    origin = getattr(s, "origin", None) if s else None
    print(f"{m:45s} {origin}")
' 2>&1 | grep -v '^INFO' | tail -10
  done

  echo "== 8. base 被 patch 文件的引用行与相关目录 =="
  docker exec "$CON" sh -c '
SP=/opt/corex311/lib/python3.11/site-packages
echo "-- gpu_model_runner 中的 host_fastpath/corex 引用 --"
grep -n "host_fastpath\|corex_host" $SP/vllm/v1/worker/gpu_model_runner.py | head -25
echo "-- ilu_flash_attn 真实路径 --"
find $SP/vllm -name "ilu_flash_attn.py" 2>/dev/null | head
echo "-- site-packages 下 corex/host 相关条目 --"
ls $SP | grep -iE "corex|host" | head -20
'

  echo "== 9. 两个 venv 的本地 wheel 来源对比 =="
  for V in "$BASE" "$NEW"; do
    echo "-- $V --"
    docker exec "$CON" sh -c "
for f in $V/lib/python3.11/site-packages/*.dist-info/direct_url.json; do
  url=\$(sed -n 's/.*\"url\": \"\\([^\"]*\\)\".*/\\1/p' \"\$f\")
  [ -n \"\$url\" ] && echo \"\$(basename \$f) -> \$url\"
done
"
  done

  echo "== 10. vllm 声明的关键依赖约束 =="
  for V in "$BASE" "$NEW"; do
    echo "-- $V --"
    timeout 120 docker exec -e PYTHONPATH= -e PYTHONHOME= "$CON" "$V/bin/python" -c '
import importlib.metadata as m
try:
    reqs = m.requires("vllm") or []
except Exception as e:
    print("ERR", e); reqs = []
for r in reqs:
    if any(k in r.lower() for k in ("transformers", "tvm", "torch", "numpy", "compressed")):
        print(r)
' 2>&1 | tail -12
  done

  echo "== 11. 真实安装 bundle / hashed 清单 / 补丁目录 =="
  docker exec "$CON" sh -c '
echo "-- /home/z30059427/corex5-py311-20261009 --"
ls -la /home/z30059427/corex5-py311-20261009 2>/dev/null | head -15
echo "-- requirements 文件 --"
find /home/z30059427/corex5-py311-20261009 -maxdepth 3 -name "requirements*" 2>/dev/null | head -15
echo "-- verify 脚本 --"
find /home/z30059427/corex5-py311-20261009 -maxdepth 3 -name "verify_corex311.py" 2>/dev/null | head -3
echo "-- huawei_ts_program 下 setup 目录 --"
ls -d /home/huawei_ts_program/corex5_py311_setup_* 2>/dev/null
'
  echo "-- host fastpath 交付目录 --"
  timeout 90 docker exec "$CON" sh -c '
for D in /home/z30059427 /home/qch /home/huawei_ts_program; do
  find $D -maxdepth 5 \( -name "BASELINE.json" -o -name "corex_host_opt.py" -o -name "corex_host_native" \) 2>/dev/null | head -10
done
'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
