#!/usr/bin/env bash
# 184 压测状态速查（只读）。
# 用法：bash /home/qch/tools/bench-status.sh
# 自动判断压测所在的容器，并在容器内做检查（run 目录只存在于容器根文件系统）。
set -uo pipefail

HOST_RUNNER=$(pgrep -f 'vllmBench_lite_(opt|base|pmu)\.sh' 2>/dev/null | head -1)

CID=""
if [ -n "${HOST_RUNNER:-}" ]; then
  CID=$(sed -n 's|.*/docker/\([0-9a-f]\{64\}\).*|\1|p' "/proc/$HOST_RUNNER/cgroup" 2>/dev/null | head -1)
fi
CONT=""
if [ -n "$CID" ]; then
  CONT=$(docker inspect -f '{{.Name}}' "$CID" 2>/dev/null | sed 's|^/||')
fi

BLOCK=$(cat <<'EOS'
say() { printf '%s\n' "$*"; }
say "== 时间 =="; say "$(date '+%F %T')"
say "容器: $(hostname)"

RUNNER=$(pgrep -f 'vllmBench_lite_(opt|base|pmu)\.sh' 2>/dev/null | head -1)
if [ -z "${RUNNER:-}" ]; then
  say "当前没有 vllmBench 脚本在跑"
  say "== 最近改动过的 run 目录 =="
  for d in $(find / -xdev -maxdepth 6 -type d -name vllmBench 2>/dev/null); do
    ls -dt "$d"/*/ 2>/dev/null | head -1
  done | head -3
  exit 0
fi

say ""
say "== 谁在跑 =="
say "pid      : $RUNNER"
say "user     : $(ps -o user= -p "$RUNNER" 2>/dev/null | tr -d ' ')"
say "cmd      : $(tr '\0' ' ' < "/proc/$RUNNER/cmdline" 2>/dev/null)"
say "start    : $(ps -o lstart= -p "$RUNNER" 2>/dev/null | sed 's/^ *//')"
say "elapsed  : $(ps -o etime= -p "$RUNNER" 2>/dev/null | tr -d ' ')"

SCRIPT=$(tr '\0' ' ' < "/proc/$RUNNER/cmdline" 2>/dev/null | awk '{print $2}')
say "script   : $SCRIPT"

BENCH=$(pgrep -f 'bench_driver\.py' 2>/dev/null | head -1)
say ""
say "== 当前 case =="
if [ -n "${BENCH:-}" ]; then
  ARG=$(tr '\0' ' ' < "/proc/$BENCH/cmdline" 2>/dev/null)
  say "pid      : $BENCH (elapsed $(ps -o etime= -p "$BENCH" 2>/dev/null | tr -d ' '))"
  say "input    : $(printf '%s' "$ARG" | sed -n 's/.*--random_input_len \([0-9]*\).*/\1/p')"
  say "output   : $(printf '%s' "$ARG" | sed -n 's/.*--random_output_len \([0-9]*\).*/\1/p')"
  say "prompts  : $(printf '%s' "$ARG" | sed -n 's/.*--num_prompts \([0-9]*\).*/\1/p')"
  say "conc     : $(printf '%s' "$ARG" | sed -n 's/.*--max-concurrency \([0-9]*\).*/\1/p')"
else
  say "没有 bench_driver 在跑（可能在 case 间隔或收尾）"
fi

RUN=""
for p in "$RUNNER" "${BENCH:-}"; do
  [ -n "${p:-}" ] || continue
  v=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^LIGHTHOST_SESSION=//p' | head -1)
  [ -n "$v" ] && { RUN=${v%/*}; break; }
done
if [ -z "$RUN" ]; then
  RUN=$(for d in $(find / -xdev -maxdepth 6 -type d -name vllmBench 2>/dev/null); do
          ls -dt "$d"/*/ 2>/dev/null | head -1
        done | head -1)
fi

say ""
say "== run 目录 =="
say "${RUN:-<未找到>}"
[ -n "$RUN" ] && [ -d "$RUN" ] || exit 0

DONE=0
if [ -f "$RUN/summary.csv" ]; then
  say "-- summary.csv --"
  head -12 "$RUN/summary.csv"
  DONE=$(( $(wc -l < "$RUN/summary.csv") - 1 ))
else
  say "(还没有 summary.csv)"
fi

say "-- case 目录（按时间）--"
for d in "$RUN"/*/; do
  [ -d "$d" ] || continue
  printf '%s  %s\n' "$(stat -c %y "$d" 2>/dev/null | cut -d. -f1)" "$(basename "$d")"
done | sort | head -12

say "-- server.log 末尾 --"
tail -4 "$RUN/logs/server.log" 2>/dev/null | cut -c1-160

say ""
say "== 预计 =="
TOTAL=$(grep -cE '^ *"[0-9]+ [0-9]+"' "$SCRIPT" 2>/dev/null || echo 0)
ELAPSED=$(ps -o etimes= -p "$RUNNER" 2>/dev/null | tr -d ' ')
if [ "${TOTAL:-0}" -gt 0 ] && [ -n "${ELAPSED:-}" ] && [ "$ELAPSED" -gt 0 ]; then
  CUR=$(( DONE + 1 ))
  AVG=$(( ELAPSED / CUR ))
  LEFT=$(( TOTAL - DONE - 1 ))
  REM=$(( AVG * LEFT ))
  say "已完成 $DONE / $TOTAL 个 case，当前第 $CUR 个"
  say "平均每 case ≈ $AVG s（粗估，output 长度不同差异较大）"
  say "预计剩余 ≈ $(( REM / 60 )) 分钟，结束约 $(date -d "+$REM seconds" '+%H:%M' 2>/dev/null || echo '?')"
else
  say "信息不足，无法估算（TOTAL=$TOTAL ELAPSED=${ELAPSED:-?}）"
fi

say ""
say "== GPU =="
ixsmi 2>/dev/null | sed -n '5,20p'
EOS
)

if [ -n "${CONT:-}" ]; then
  printf '%s\n' "$BLOCK" | docker exec -i "$CONT" bash -s
else
  printf '%s\n' "$BLOCK" | bash -s
fi
