#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读诊断 py312_litehost_gap_20261125_093806；顺带核对缓存产物来自启动窗口还是 case 窗口。
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

D 'B=/home/huawei_ts_program/litehost_perf_opt/vllmBench
R=$B/py312_litehost_gap_20261125_093806
echo "-- run 目录"; ls -la --time-style=long-iso $R 2>&1
echo "-- config.txt"; cat $R/config.txt 2>&1
echo "-- logs 目录"; ls -la --time-style=long-iso $R/logs 2>&1
echo "-- lint"; wc -l $R/logs/*.log 2>&1'

D 'B=/home/huawei_ts_program/litehost_perf_opt/vllmBench
R=$B/py312_litehost_gap_20261125_093806
L=$R/logs/server.log
echo "-- 阶段"; grep -nE "activated|pinned to cpu|Capturing CUDA graphs|ompil|Application startup complete" $L 2>/dev/null | tail -20
echo "-- 报错"; grep -nE "ERROR|Traceback|FileNotFoundError|RuntimeError|Killed|OOM|No space|stalled" $L 2>/dev/null | tail -25
echo "-- tail 60"; tail -n 60 $L 2>&1'

D 'B=/home/huawei_ts_program/litehost_perf_opt/vllmBench
R=$B/py312_litehost_gap_20261125_093806
for f in $R/logs/*.log; do
  case $f in *server.log) continue;; esac
  echo "-- $(basename $f) tail"; tail -n 15 $f 2>&1
done'

D 'echo "-- 磁盘"; df -h / /tmp /home/huawei_ts_program 2>&1 | tail -4
echo "-- 内存"; free -m 2>&1 | tail -3
echo "-- PCH"; ls -la --time-style=long-iso /tmp/torchinductor_root/precompiled_headers/*.h 2>&1'

D 'C=/home/huawei_ts_program/inductor_cache_py312
echo "-- .so 总数"; find $C -name "*.so" 2>/dev/null | wc -l
echo "-- .so 按分钟分布（最近两天）"
find $C -name "*.so" -newermt "2026-11-23" -printf "%TY-%Tm-%Td %TH:%TM\n" 2>/dev/null | sort | uniq -c | sort -k2
echo "-- 缓存顶层最新 8 项"; ls -1t $C 2>/dev/null | head -8'

D 'B=/home/huawei_ts_program/litehost_perf_opt/vllmBench
echo "-- 最近 run 与启动时间"
for d in $B/*/; do
  s=$(sed -n "s/^started=//p" $d/config.txt 2>/dev/null)
  w=$(sed -n "s/^warmup_only=//p" $d/config.txt 2>/dev/null)
  [[ -n "$s" ]] && echo "$(basename $d)  started=$s  warmup_only=${w:-0}"
done | sort -k2 | tail -8'
PROBE_EOF
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE_SH" 2>&1 | head -400

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
