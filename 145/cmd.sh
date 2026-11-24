#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：198 上对比 11-23 成功运行与 11-24 100823 的 capture 耗时、缓存写入、负载。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
PROBE=/tmp/probe198c.sh

{
  echo "### server: 145 -> 198"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
C=vllm
VB=/home/huawei_ts_program/litehost_perf_opt/vllmBench
CACHE=/home/huawei_ts_program/inductor_cache_py312

echo "== 1. 11-23 两次运行的 capture 时间线 =="
for D in py312_litehost_gap_20261123_155113 py312_litehost_gap_20261123_155940; do
  echo "---- $D"
  docker exec $C bash -lc "grep -nE 'pinned to cpu|Loading weights took|capturing|Capturing|startup complete|Application startup|\$D' $VB/$D/logs/server.log 2>/dev/null | cut -c1-180 | head -20"
  docker exec $C bash -lc "grep -oE 'Capturing CUDA graphs[^|]*\| [0-9]+/35 \[[0-9:]+<' $VB/$D/logs/server.log 2>/dev/null | tail -3"
  docker exec $C bash -lc "ls $VB/$D; echo '-- summary'; head -3 $VB/$D/summary.csv 2>/dev/null"
done

echo "== 2. 11-23 运行的 config（含 MOCK_TP_CPUS 吗）=="
docker exec $C bash -lc "cat $VB/py312_litehost_gap_20261123_155940/config.txt"

echo "== 3. capture 起止在 100823 日志中的精确行 =="
docker exec $C bash -lc "grep -n 'Capturing' $VB/py312_litehost_gap_20261124_100823/logs/server.log | cut -c1-160"

echo "== 4. 今天缓存有没有被写过 =="
docker exec $C bash -lc "echo '-- pinned cache 今日新文件:'; find $CACHE -newermt '2026-11-24 09:00' | head -20; echo '-- 全部文件数:'; find $CACHE -type f | wc -l"
docker exec $C bash -lc "echo '-- /tmp/torchinductor_root 今日新文件:'; find /tmp/torchinductor_root -newermt '2026-11-24 09:00' -type f | head -20; stat -c '%n %y %s' /tmp/torchinductor_root/precompiled_headers/*.gch 2>/dev/null | head -4"

echo "== 5. 缓存里的 5 个 py（变体名）=="
docker exec $C bash -lc "find $CACHE -name '*.py' | xargs -r ls -l | head -8"

echo "== 6. 负载与 cgroup =="
uptime; cat /proc/loadavg
docker inspect $C --format 'cpuset={{.HostConfig.CpusetCpus}} cpuquota={{.HostConfig.CpuQuota}} cpushares={{.HostConfig.CpuShares}} nano={{.HostConfig.NanoCpus}}'
docker exec $C bash -lc "cat /sys/fs/cgroup/cpu.max 2>/dev/null; nproc; taskset -pc \$\$"

echo "== 7. 测试留下的 perf 数据 =="
docker exec $C bash -lc "find /home /root /tmp -maxdepth 3 -name 'perf.data*' -newermt '2026-11-24 00:00' 2>/dev/null | head; ls -l /tmp/perf-*.map 2>/dev/null | head -4"

echo "== 8. session.json / 其它证据 =="
docker exec $C bash -lc "cat $VB/py312_litehost_gap_20261124_100823/session.json 2>/dev/null | head -c 800; echo; ls -l $VB/py312_litehost_gap_20261124_100823/control"
PROBE_EOF

  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE" 2>&1 | head -200

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
