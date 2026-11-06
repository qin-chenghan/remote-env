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
  # 第二批：仍然严格只读。不安装、不建 venv、不动服务。
  # 目标：把上轮发现的“包集合漂移”量化，并定位真实 bundle 与 host fastpath 补丁来源。

  CON=corex5-py311
  BASE=/opt/corex311
  NEW=/opt/corex311-cpython-vllm

  echo "== 1. 包集合漂移量化（复用上轮 /tmp 文件，不存在则重建）=="
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

  echo "== 2. host fastpath 模块的真实位置（find_spec，不 import vllm 本体）=="
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

  echo "== 3. base 里被 patch 的文件长什么样（只看 import 行与文件位置）=="
  docker exec "$CON" sh -c '
SP=/opt/corex311/lib/python3.11/site-packages
echo "-- host_fastpath 引用行 --"
grep -n "host_fastpath\|corex_host" $SP/vllm/v1/worker/gpu_model_runner.py | head -25
echo "-- ilu_flash_attn 真实路径 --"
find $SP/vllm -name "ilu_flash_attn.py" -o -name "*ilu*attn*.py" 2>/dev/null | head
echo "-- corex 相关顶层目录/文件 --"
ls -d $SP/corex* 2>/dev/null
ls $SP | grep -iE "corex|host" | head -20
'

  echo "== 4. 两个 venv 的“本地 wheel 来源”清单对比 =="
  for V in "$BASE" "$NEW"; do
    echo "-- $V --"
    docker exec "$CON" sh -c "
for f in $V/lib/python3.11/site-packages/*.dist-info/direct_url.json; do
  url=\$(sed -n 's/.*\"url\": \"\\([^\"]*\\)\".*/\\1/p' \"\$f\")
  [ -n \"\$url\" ] && echo \"\$(basename \$f) -> \$url\"
done
"
  done

  echo "== 5. vllm 声明的 transformers / tvm 约束 =="
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

  echo "== 6. 定位真实安装 bundle 与 hashed 清单 =="
  docker exec "$CON" sh -c '
echo "-- /home/z30059427/corex5-py311-20261009 --"
ls -la /home/z30059427/corex5-py311-20261009 2>/dev/null | head -15
echo "-- requirements 文件 --"
find /home/z30059427/corex5-py311-20261009 -maxdepth 3 -name "requirements*" 2>/dev/null | head -15
echo "-- verify 脚本 --"
find /home/z30059427/corex5-py311-20261009 -maxdepth 3 -name "verify_corex311.py" 2>/dev/null | head -3
echo "-- huawei_ts_program 下的 setup 目录 --"
ls -d /home/huawei_ts_program/corex5_py311_setup_* 2>/dev/null
'
  echo "-- host fastpath 补丁交付目录（只找标志文件）--"
  timeout 90 docker exec "$CON" sh -c '
for D in /home/z30059427 /home/qch /home/huawei_ts_program; do
  find $D -maxdepth 5 \( -name "BASELINE.json" -o -name "corex_host_opt.py" -o -name "corex_host_native" \) 2>/dev/null | head -10
done
'

  echo "== 7. 新 venv 里已装的“非 PyPI 来源”与编译扩展抽查 =="
  docker exec "$CON" sh -c '
SP=/opt/corex311-cpython-vllm/lib/python3.11/site-packages
echo "-- apache-tvm-ffi / ixformer 的安装形态 --"
ls -d $SP/apache_tvm_ffi* $SP/ixformer* 2>/dev/null
for d in $SP/apache_tvm_ffi*.dist-info $SP/ixformer*.dist-info; do
  [ -d "$d" ] && echo "[$d]" && ls "$d" | head -5 && { [ -f "$d/direct_url.json" ] && cat "$d/direct_url.json"; }
done
echo "-- 顶层 .so 数量（新 vs base）--"
echo -n "new : "; find $SP -maxdepth 2 -name "*.so" | wc -l
echo -n "base: "; find /opt/corex311/lib/python3.11/site-packages -maxdepth 2 -name "*.so" | wc -l
'

  echo "== 8. 现场确认（服务仍在跑，不打扰）=="
  pgrep -af 'vllm.entrypoints|bench_driver' 2>/dev/null | head -5 || true
  docker exec "$CON" sh -c 'df -h /opt | tail -1'

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
