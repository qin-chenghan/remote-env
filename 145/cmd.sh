#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：qemu 重启后只读巡检 —— 宿主指纹、旧缓存 .so、崩溃残留、导入耗时。
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

D 'echo "-- 主机"; uptime; free -m | tail -3
echo "-- 容器"; docker ps --format "{{.Names}}  {{.RunningFor}}  {{.Status}}" 2>&1 | head -5
echo "-- run 目录"; ls -1dt /home/huawei_ts_program/litehost_perf_opt/vllmBench/*/ 2>/dev/null | head -6'

D 'echo "-- 宿主指纹"
grep -m1 "^Features" /proc/cpuinfo
{ grep -m1 "^Features" /proc/cpuinfo; g++ -dumpfullversion -dumpversion 2>/dev/null; } | md5sum | cut -c1-10 | sed "s/^/host_tag=/"
g++ --version 2>&1 | head -1
echo "-- 缓存目录"; ls -1d /home/huawei_ts_program/inductor_cache_py* /home/huawei_ts_program/inductor_cache_py*/h-* 2>/dev/null
echo "-- 旧 .so"; find /home/huawei_ts_program/inductor_cache_py312 -name "*.so" -printf "%TY-%Tm-%Td %TH:%TM %s %p\n" 2>/dev/null
echo "-- PCH"; ls -la --time-style=long-iso /tmp/torchinductor_root/precompiled_headers/ 2>&1 | head -12'

D 'C=/home/huawei_ts_program/inductor_cache_py312
echo "-- 缓存 .so 的 SVE 类指令计数（>0 表示编进了 SVE）"
for f in $(find $C -name "*.so" 2>/dev/null); do
  n=$(objdump -d "$f" 2>/dev/null | grep -cE "ptrue|whilelo|ld1w|ld1b|st1w|sdot|bfdot|[[:space:]]z[0-9]+\.")
  echo "$n  $(basename $f)"
done'

D 'echo "-- core 配置"; cat /proc/sys/kernel/core_pattern 2>&1; ulimit -c 2>&1
echo "-- core 文件"; ls -la /var/lib/systemd/coredump/ /var/crash 2>/dev/null | head -10
find /home/huawei_ts_program -maxdepth 3 -name "core*" -newermt "2026-11-24" 2>/dev/null | head -10
echo "-- dmesg 信号相关"; dmesg 2>/dev/null | grep -iE "traps:|segfault|invalid opcode|illegal|killed process|out of memory|coredump" | tail -20
echo "-- dmesg 尾部"; dmesg 2>/dev/null | tail -12'

D 'P=/usr/local/bin/python3
echo "-- /etc/hosts"; cat /etc/hosts 2>&1 | head -10
echo "-- resolv.conf"; cat /etc/resolv.conf 2>&1 | head -6
echo "-- 主机名解析（最多 30s）"; time timeout 30 getent hosts $(hostname) 2>&1
echo "-- import torch 计时（最多 200s）"; time timeout 200 $P -c "import torch; print(torch.__version__)" 2>&1 | tail -4
echo "-- import vllm 最慢包（最多 320s）"; timeout 320 env PYTHONPATH=/home/qch/mock_vllm CUDA_VISIBLE_DEVICES=0,1,2,3 $P -X importtime -c "import vllm" 2>&1 | sort -t"|" -k2 -n | tail -8'
PROBE_EOF
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE_SH" 2>&1 | head -400

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
