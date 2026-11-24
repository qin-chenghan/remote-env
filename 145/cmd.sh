#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：只读核对「内核缓存是启动阶段产物还是 case 阶段产物」。
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
echo "-- 已有 run 的启动时间"
for d in $B/*/; do
  s=$(sed -n "s/^started=//p" $d/config.txt 2>/dev/null)
  w=$(sed -n "s/^warmup_only=//p" $d/config.txt 2>/dev/null)
  [[ -n "$s" ]] && echo "$(basename $d)  started=$s  warmup_only=${w:-0}"
done | sort -k2'

D 'B=/home/huawei_ts_program/litehost_perf_opt/vllmBench
for r in test-warmup test-warmup1 test-warmup2; do
  L=$B/$r/logs/server.log
  echo "===== $r"
  [[ -f $L ]] || { echo "(无 server.log)"; continue; }
  echo "-- 阶段时间戳"
  grep -hoE "^\([A-Za-z_]+ pid=[0-9]+\) (INFO|WARNING) [0-9-]+ [0-9:]+ \[[^]]*\] (Platform plugin iluvatar is activated|Application startup complete|Starting vLLM API server)" $L 2>/dev/null | tail -3
  grep -hoE "Capturing CUDA graphs \(decode, FULL\): 100%" $L | head -1
  echo "-- 编译相关行"
  grep -nE "ompil|Using cached|torch\.compile" $L 2>/dev/null | tail -8
done'

D 'C=/home/huawei_ts_program/inductor_cache_py312
echo "-- .so 总数"; find $C -name "*.so" 2>/dev/null | wc -l
echo "-- .so 按分钟分布"
find $C -name "*.so" -printf "%TY-%Tm-%Td %TH:%TM\n" 2>/dev/null | sort | uniq -c | sort -k2
echo "-- .cpp/.py/.json 按天分布"
find $C \( -name "*.cpp" -o -name "*.py" -o -name "*.json" \) -printf "%TY-%Tm-%Td\n" 2>/dev/null | sort | uniq -c
echo "-- 最新 5 个 .so"
find $C -name "*.so" -printf "%TY-%Tm-%Td %TH:%TM:%TS %p\n" 2>/dev/null | sort | tail -5
echo "-- 缓存顶层项数"; ls -1 $C 2>/dev/null | wc -l
echo "-- 顶层最新 8 项"; ls -1t $C 2>/dev/null | head -8'
PROBE_EOF
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE_SH" 2>&1 | head -300

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
