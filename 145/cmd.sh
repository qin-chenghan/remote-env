#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：198 上取 coredump/OOM 证据、缓存全量 mtime、开机时间、新 key 痕迹。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
PROBE=/tmp/probe198e.sh

{
  echo "### server: 145 -> 198"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
C=vllm
CACHE=/home/huawei_ts_program/inductor_cache_py312

echo "== 1. 开机/负载历史 =="
uptime -s; uptime
last reboot 2>/dev/null | head -3

echo "== 2. 11:15-11:35 内核日志（OOM/segfault）=="
journalctl -k --since '2026-11-24 11:10' --until '2026-11-24 11:40' 2>/dev/null | grep -iE 'oom|killed process|segfault|traps' | head -10 || echo "(journalctl -k 不可用)"
echo "-- systemd-coredump --"
coredumpctl list 2>/dev/null | tail -8 || echo "(无 coredumpctl)"

echo "== 3. pinned cache 全量 =="
docker exec $C bash -lc "find $CACHE -type f -printf '%TY-%Tm-%Td %TH:%TM %s %p\n' | sort | head -40"

echo "== 4. 全机找 inductor 缓存目录 =="
ls -d /tmp/torchinductor* /home/*/inductor* /root/torchinductor* 2>/dev/null
docker exec $C bash -lc "find /tmp/torchinductor_root -type f -printf '%TY-%Tm-%Td %TH:%TM %s %p\n' | sort | tail -12"

echo "== 5. 找新 key cjavtv4n 的产物 =="
docker exec $C bash -lc "grep -rl . /dev/null 2>/dev/null; find / -maxdepth 8 -name 'cjavtv4n*' 2>/dev/null | head -5"

echo "== 6. 11-23 成功运行是否也重建过 PCH =="
docker exec $C bash -lc "stat -c '%n %y' /tmp/torchinductor_root/precompiled_headers/*.gch 2>/dev/null"

echo "== 7. 容器内可见的 CPU 拓扑（与绑核 8/10/12/14 对应）=="
docker exec $C bash -lc "nproc; grep -c ^processor /proc/cpuinfo; cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null"
lscpu 2>/dev/null | grep -E 'Model name|^CPU\(s\)|NUMA node0' | head -4
PROBE_EOF

  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE" 2>&1 | head -160

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
