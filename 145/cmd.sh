#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读取证 worker 崩溃信号 + 缓存 .so 指令集是否与当前 CPU 匹配。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
PROBE_SH=/tmp/probe198w.sh

{
  echo "### server: 145 -> 198  (只读)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  cat > "$PROBE_SH" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
D() { docker exec vllm bash -lc "$1" 2>&1 | sed '/^Authorized users only/d'; }

D 'echo "-- dmesg 信号/崩溃相关"
dmesg 2>/dev/null | grep -iE "traps:|segfault|invalid opcode|illegal|killed process|oom|out of memory|audit" | tail -25
echo "-- dmesg 最后 40 行"
dmesg 2>/dev/null | tail -40'

D 'echo "-- core 配置"
cat /proc/sys/kernel/core_pattern 2>&1
ulimit -c 2>&1
echo "-- core 文件"
ls -la /var/lib/systemd/coredump/ /var/lib/apport/coredump /cores /tmp/core* 2>/dev/null | head -20
echo "-- 目录下 core"
find /home/huawei_ts_program/litehost_perf_opt -maxdepth 2 -name "core*" -newermt "2026-11-25 00:00" 2>/dev/null | head'

D 'echo "-- CPU"
grep -m1 "^Features" /proc/cpuinfo
grep -m1 -E "CPU part|CPU implementer|model name" /proc/cpuinfo
echo "-- gcc"
g++ --version 2>&1 | head -2
echo "-- 工具"
command -v objdump llvm-objdump readelf 2>&1'

D 'C=/home/huawei_ts_program/inductor_cache_py312
echo "-- 缓存 .so"
find $C -name "*.so" -printf "%TY-%Tm-%Td %TH:%TM %s %p\n" 2>/dev/null
echo "-- 缓存 .py"
find $C -name "*.py" -printf "%TY-%Tm-%Td %TH:%TM %p\n" 2>/dev/null | head -10
echo "-- SVE/高级指令计数（缓存 .so）"
for f in $(find $C -name "*.so" 2>/dev/null); do
  n=$(objdump -d "$f" 2>/dev/null | grep -cE "ptrue|whilelo|ld1w|ld1b|st1w|sdot|bfdot|[[:space:]]z[0-9]+\.")
  echo "$n  $(basename $f)"
done'

D 'C=/home/huawei_ts_program/inductor_cache_py312
echo "-- 缓存文件里的编译命令行/宏（如有）"
grep -rhoE "\-march=[a-z0-9.+_-]+|AT_BUILD_ARM_VEC256[A-Z_]*|__ARM_FEATURE_[A-Z0-9_]+" $C 2>/dev/null | sort | uniq -c | head -20
echo "-- PCH 目录全量"
ls -la --time-style=long-iso /tmp/torchinductor_root/precompiled_headers/ 2>&1 | head -15
echo "-- PCH gch 大小"
ls -la --time-style=long-iso /tmp/torchinductor_root/precompiled_headers/*.gch 2>&1'
PROBE_EOF
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE_SH" 2>&1 | head -400

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
