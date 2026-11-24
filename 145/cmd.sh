#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：198 上取 100823 的完整时间线、preflight、内存/OOM、以及现场 py312 脚本版本。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
PROBE=/tmp/probe198b.sh

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
D=$VB/py312_litehost_gap_20261124_100823

echo "== 1. 100823 server.log 前 30 行 =="
docker exec $C bash -lc "head -30 $D/logs/server.log | cut -c1-200"

echo "== 2. capture 前后（第 190-235 行）=="
docker exec $C bash -lc "sed -n '190,235p' $D/logs/server.log | cut -c1-220"

echo "== 3. 所有带时间戳的行（间隔取样）=="
docker exec $C bash -lc "grep -E '^\((Worker|EngineCore|APIServer|Worker_TP)[^)]*\) ' $D/logs/server.log | grep -oE '^\([^)]*\) [A-Z]+ [0-9-]+ [0-9:]+ \[[^]]*\]' | uniq | head -60"

echo "== 4. preflight =="
docker exec $C bash -lc "echo '-- 100823'; cat $D/logs/preflight.log 2>/dev/null | head -40"
docker exec $C bash -lc "echo '-- 094434'; cat $VB/py312_litehost_gap_20261124_094434/logs/preflight.log 2>/dev/null | head -30"

echo "== 5. 内存与 OOM =="
free -g | head -3
docker inspect $C --format 'mem_limit={{.HostConfig.Memory}} shm={{.HostConfig.ShmSize}} started={{.State.StartedAt}} restarts={{.RestartCount}}'
dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -8 || echo "(dmesg 不可读)"

echo "== 6. 现场脚本版本 =="
docker exec $C bash -lc "ls -l /home/huawei_ts_program/litehost_perf_opt/*.sh 2>/dev/null; ls -l /home/huawei_ts_program/litehost_perf_opt/tools 2>/dev/null | head"
docker exec $C bash -lc "for f in /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_base_mock_py312.sh /home/huawei/qch/tools/vllmBench_lite_base_mock_py312.sh; do [ -f \$f ] && { echo \"-- \$f\"; md5sum \$f; grep -nE 'TORCHINDUCTOR|SERVER_WAIT_TIMEOUT|PREFIX=|MODEL_PATH=' \$f | head -8; }; done"

echo "== 7. inductor 缓存现状 =="
docker exec $C bash -lc "for c in /tmp/torchinductor_root /home/huawei_ts_program/inductor_cache_py312; do echo \"-- \$c\"; ls -l \$c | head -6; done"
docker exec $C bash -lc "find /tmp/torchinductor_root -name '*.py' -newermt '2026-11-24 09:00' | head -10; echo count=\$(find /tmp/torchinductor_root -name '*.py' | wc -l)"

echo "== 8. 198 磁盘/内存概况 =="
df -h / /home 2>/dev/null | head -5
grep -cE 'MemTotal' /proc/meminfo >/dev/null; awk '/MemTotal|MemAvailable|SwapTotal/{print}' /proc/meminfo
PROBE_EOF

  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE" 2>&1 | head -240

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
