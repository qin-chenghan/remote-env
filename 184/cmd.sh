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
  # 重建 /opt/corex311-cpython-vllm 前的只读准备：
  # A. bundle 的安装脚本能否指定目标目录
  # B. base 相对原始 vllm wheel 的完整补丁足迹
  # C. tokens 补丁的交付来源
  # 不删除、不安装、不建 venv。

  CON=corex5-py311
  BASE=/opt/corex311
  NEW=/opt/corex311-cpython-vllm
  SP="$BASE/lib/python3.11/site-packages"
  BUNDLE=/home/z30059427/corex5-py311-20261009
  WHEEL="$BUNDLE/vendor/vllm-0.23.0+corex.5.0.0-py3-none-any.whl"

  echo "== 1. bundle 安装脚本与清单 =="
  docker exec "$CON" sh -c "
B=$BUNDLE
echo '---- install_corex311.sh'
cat \$B/install_corex311.sh
echo '---- README 前 120 行'
sed -n '1,120p' \$B/README.md
echo '---- requirements-vendor-py311.txt'
cat \$B/requirements-vendor-py311.txt
echo '---- requirements-all.hashed.txt 行数与前 10 行'
wc -l \$B/requirements-all.hashed.txt
sed -n '1,10p' \$B/requirements-all.hashed.txt
echo '---- vendor 目录'
ls -la \$B/vendor
"

  echo "== 2. base 相对原始 vllm wheel 的完整 diff =="
  docker exec "$CON" sh -c "
SP=$SP
W=$WHEEL
rm -rf /tmp/vllm_wheel_x
mkdir -p /tmp/vllm_wheel_x
/opt/corex311/bin/python -m zipfile -e \"\$W\" /tmp/vllm_wheel_x
echo '-- diff -rq（排除 pycache）--'
diff -rq /tmp/vllm_wheel_x/vllm \$SP/vllm 2>/dev/null | grep -v __pycache__ | head -120
echo '-- 新 venv 是否 pristine --'
diff -rq /tmp/vllm_wheel_x/vllm $NEW/lib/python3.11/site-packages/vllm 2>/dev/null | grep -v __pycache__ | head -40
"

  echo "== 3. tokens 补丁来源 =="
  docker exec "$CON" sh -c "
SP=$SP
echo '-- transfer 下的 wheel/包 --'
ls -la --time-style=long-iso /home/qch/transfer/*.whl 2>/dev/null
find /home/qch/transfer -maxdepth 2 -iname '*hotspot*' -printf '%10s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | head -20
echo '-- site-packages 里 hotspot 相关 --'
find \$SP -maxdepth 2 -iname '*hotspot*' 2>/dev/null | head -20
echo '-- get_top_tokens 定义位置 --'
grep -rn 'def get_top_tokens' \$SP/vllm --include='*.py' 2>/dev/null | head -5
"

  echo "== 4. 新 venv 当前占用与磁盘 =="
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
