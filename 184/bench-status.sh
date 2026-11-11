#!/usr/bin/env bash
# 184 压测状态速查（只读）。
# 用法：bash /home/qch/tools/bench-status.sh
# 说明：在宿主机执行；容器内的进程在宿主 PID 命名空间可见。
set -uo pipefail

say() { printf '%s\n' "$*"; }
now() { date '+%F %T'; }

say "== 时间 =="; say "$(now)"

RUNNER=$(pgrep -f 'vllmBench_lite_(opt|base|pmu)\.sh' 2>/dev/null | head -1)
if [ -z "${RUNNER:-}" ]; then
  say "当前没有 vllmBench 脚本在跑"
  say "== 最近改动过的 run 目录 =="
  for d in $(find / -xdev -maxdepth 5 -type d -name vllmBench 2>/dev/null); do
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
say "cwd      : $(readlink "/proc/$RUNNER/cwd" 2>/dev/null)"

BENCH=$(pgrep -f 'bench_driver\.py' 2>/dev/null | head -1)
say ""
say "== 当前 case =="
if [ -n "${BENCH:-}" ]; then
  say "pid      : $BENCH (elapsed $(ps -o etime= -p "$BENCH" 2>/dev/null | tr -d ' '))"
  ARG=$(tr '\0' ' ' < "/proc/$BENCH/cmdline" 2>/dev/null)
  say "input    : $([ -n "$ARG" ] && printf '%s' "$ARG" | sed -n 's/.*--random_input_len \([0-9]*\).*/\1/p')"
  say "output   : $([ -n "$ARG" ] && printf '%s' "$ARG" | sed -n 's/.*--random_output_len \([0-9]*\).*/\1/p')"
  say "prompts  : $([ -n "$ARG" ] && printf '%s' "$ARG" | sed -n 's/.*--num_prompts \([0-9]*\).*/\1/p')"
  say "conc     : $([ -n "$ARG" ] && printf '%s' "$ARG" | sed -n 's/.*--max-concurrency \([0-9]*\).*/\1/p')"
else
  say "没有 bench_driver 在跑（可能在 case 间隔或收尾）"
fi

# run 目录：优先从进程环境取 LIGHTHOST_SESSION
RUN=""
for p in "$RUNNER" "${BENCH:-}"; do
  [ -n "${p:-}" ] || continue
  v=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^LIGHTHOST_SESSION=//p' | head -1)
  [ -n "$v" ] && { RUN=${v%/*}; break; }
done
if [ -z "$RUN" ]; then
  RUN=$(for d in $(find / -xdev -maxdepth 5 -type d -name vllmBench 2>/dev/null); do
          ls -dt "$d"/*/ 2>/dev/null | head -1
        done | head -1)
fi

say ""
say "== run 目录 =="
say "${RUN:-<未找到>}"
[ -n "$RUN" ] && [ -d "$RUN" ] || exit 0

say "-- summary.csv --"
if [ -f "$RUN/summary.csv" ]; then
  head -12 "$RUN/summary.csv"
  DONE=$(( $(wc -l < "$RUN/summary.csv") - 1 ))
else
  say "(还没有 summary.csv)"
  DONE=0
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
TOTAL=$(grep -cE '^ *"[0-9]+ [0-9]+"' /home/huawei_ts_program/litehost_perf_opt/vllmBench_lite_opt.sh 2>/dev/null || echo 0)
ELAPSED=$(ps -o etimes= -p "$RUNNER" 2>/dev/null | tr -d ' ')
if [ "${TOTAL:-0}" -gt 0 ] && [ -n "${ELAPSED:-}" ] && [ "$ELAPSED" -gt 0 ]; then
  CUR=$(( DONE + 1 ))
  AVG=$(( ELAPSED / CUR ))
  LEFT=$(( TOTAL - DONE - 1 ))
  REM=$(( AVG * LEFT ))
  say "已完成 $DONE / $TOTAL 个 case，当前第 $CUR 个已跑 $(( ELAPSED - DONE * AVG ))s"
  say "平均每 case ≈ $AVG s（粗估，不同 output 长度差异较大）"
  say "预计剩余 ≈ $(( REM / 60 )) 分钟，结束约 $(date -d "+$REM seconds" '+%H:%M' 2>/dev/null || echo '?')"
else
  say "信息不足，无法估算（TOTAL=$TOTAL ELAPSED=${ELAPSED:-?}）"
fi

say ""
say "== GPU =="
ixsmi 2>/dev/null | sed -n '5,20p'
