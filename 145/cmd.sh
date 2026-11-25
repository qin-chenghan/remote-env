#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读取证 20261125_093806 —— 启动时间线、capture 卡点、残留进程、今日缓存写入。
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
R=/home/huawei_ts_program/litehost_perf_opt/vllmBench/py312_litehost_gap_20261125_093806

D 'echo "-- 当前进程"; ps -eo pid,ppid,stat,pcpu,etime,cmd --sort=-pcpu 2>/dev/null | head -15
echo "-- VLLM worker 进程数"; ps -ef 2>/dev/null | grep -c "[V]LLM::"
echo "-- dmesg 尾部"; dmesg 2>/dev/null | tail -15 || echo "(dmesg 不可用)"'

D 'L=/home/huawei_ts_program/litehost_perf_opt/vllmBench/py312_litehost_gap_20261125_093806/logs/server.log
echo "===== server.log 1-130"
sed -n "1,130p" $L'

D 'L=/home/huawei_ts_program/litehost_perf_opt/vllmBench/py312_litehost_gap_20261125_093806/logs/server.log
echo "===== server.log 131-262"
sed -n "131,262p" $L'

D 'L=/home/huawei_ts_program/litehost_perf_opt/vllmBench/py312_litehost_gap_20261125_093806/logs/server.log
echo "-- Worker_TP 全部消息"; grep -n "Worker_TP" $L 2>/dev/null | tail -30
echo "-- mock_gpu 全部消息"; grep -n "mock_gpu" $L 2>/dev/null | tail -30'

D 'P=/usr/local/lib/python3.12/site-packages/vllm
echo "-- compilation_times 调用点"; grep -n "compilation_times" $P/v1/engine/core.py | head -5
echo "-- core.py 950-985"; sed -n "950,985p" $P/v1/engine/core.py
echo "-- cancelled 来源"; grep -n "cancelled" $P/distributed/device_communicators/shm_broadcast.py | head -5
echo "-- shm_broadcast 690-712"; sed -n "690,712p" $P/distributed/device_communicators/shm_broadcast.py'

D 'C=/home/huawei_ts_program/inductor_cache_py312
echo "-- 今日缓存新文件（09:00 之后）"; find $C -newermt "2026-11-25 09:00" -printf "%TH:%TM %p\n" 2>/dev/null | sort | head -30
echo "-- /tmp/torchinductor_root 今日新文件"; find /tmp/torchinductor_root -newermt "2026-11-25 09:00" -printf "%TH:%TM %p\n" 2>/dev/null | sort | head -20
echo "-- control 目录"; ls -la --time-style=long-iso /home/huawei_ts_program/litehost_perf_opt/vllmBench/py312_litehost_gap_20261125_093806/control 2>&1
echo "-- perf 采样文件"; ls -la --time-style=long-iso /tmp/perf-*.map 2>/dev/null | tail -6'
PROBE_EOF
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE_SH" 2>&1 | head -600

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
