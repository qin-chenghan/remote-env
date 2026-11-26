#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "### 本轮写入：在 203 上对 e2e base1 的四个 case（1/2048、128/128、1024/1024、2048/1）"
  echo "###           采集 torch profiler timeline + ixsys trace，口径与 e2e-analysis-base1 一致"
  echo "###           （base、100 prompts、并发 8、16 warmups、PREFIX=/opt/corex311、端口 8848）。"
  echo "###           会启动/停止 vLLM 服务，写 /home/qch/1126analysis/ 下的新目录；"
  echo "###           不动驱动、不装包、不改内核参数、不删任何已有数据。"
  echo "###           预计 50–65 分钟。"
  set +x

  # ================= 0. 前置检查（只读） =================
  echo
  echo "== 0. 前置检查 =="
  uname -m; nproc
  df -h /home | tail -1
  free_gb=$(df -BG --output=avail /home | tail -1 | tr -dc '0-9')
  echo "free_home_gb=$free_gb"
  if (( free_gb < 4 )); then
      echo "!! /home 仅剩 ${free_gb}G。本轮的 timeline + ixsys 预计需要 2.5–3.5G，"
      echo "!! 低于 4G 不启动。请先腾出空间（只由你决定删/移哪些旧数据）。"
      exit 16
  fi
  echo "multi_engine=$(cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null || echo unknown)"
  echo "（只记录，不改；与 e2e-analysis-base1 的运行条件对照用）"

  echo "-- 已有服务 / 采集进程 --"
  if pgrep -af '[v]llm.entrypoints.openai.api_server'; then echo "!! 已有 vllm 服务在跑，先停"; exit 10; fi
  if pgrep -af '[/]usr/local/corex/bin/ixsys'; then echo "!! 已有 ixsys 在跑，先停"; exit 11; fi

  echo "-- GPU 占用（共享机，先确认没人在跑活） --"
  IXSMI="$(command -v ixsmi || echo /usr/local/corex/bin/ixsmi)"
  if [[ -x "$IXSMI" ]]; then
      "$IXSMI" 2>&1 | head -50
      GPU_CSV="$("$IXSMI" --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null)"
      echo "-- 显存查询 --"
      echo "${GPU_CSV:-（query 不支持，看上面的完整输出）}"
      if [[ -n "$GPU_CSV" ]] && echo "$GPU_CSV" | awk -F', *' '$2>2048{print "!! GPU "$1" 已用 "$2" MiB"}' | grep -q .; then
          echo "!! 有卡显存占用超过 2 GiB，本轮不启动，先确认占用者"
          exit 12
      fi
  else
      echo "!! 找不到 ixsmi，无法确认 GPU 空闲，本轮不启动"
      exit 13
  fi
  if command -v fuser >/dev/null 2>&1; then
      echo "-- /dev/iluvatar0-3 占用 --"
      BUSYDEVS=$(fuser /dev/iluvatar0 /dev/iluvatar1 /dev/iluvatar2 /dev/iluvatar3 2>/dev/null)
      echo "${BUSYDEVS:-（无进程占用）}"
      [[ -n "$BUSYDEVS" ]] && { echo "!! 显卡设备被其他进程占用，本轮不启动"; exit 12; }
  fi

  echo "-- 端口 8848（不 kill 任何进程，占用就退出） --"
  if command -v ss >/dev/null 2>&1; then
      PORT_HIT=$(ss -ltn 2>/dev/null | awk '$4 ~ /:8848$/')
  else
      PORT_HIT=$(netstat -ltn 2>/dev/null | awk '$4 ~ /:8848$/')
  fi
  echo "${PORT_HIT:-（空闲）}"
  [[ -n "$PORT_HIT" ]] && { echo "!! 8848 已被占用，本轮不启动（不动别人的任务）"; exit 18; }

  echo "-- 容器与脚本 --"
  docker ps --format '{{.Names}}' | grep -qx corex5-py311 && echo "容器 corex5-py311 在" \
      || { echo "!! 容器 corex5-py311 不在"; exit 14; }
  TK=/home/qch/scripts/litehost_perf
  IX_SH="$TK/timeline_ixsys_base.sh"
  TL_SH="$TK/vllmBench_lite_base_timeline.sh"
  for f in "$IX_SH" "$TL_SH" "$TK/procutil.py" "$TK/lhctl.py"; do
      [[ -f "$f" ]] || { echo "!! 缺文件: $f"; exit 15; }
  done
  echo "ixsys:    $IX_SH"
  echo "timeline: $TL_SH"
  echo "toolkit:  $TK"
  [[ -d /home/hc/modules/Qwen3-32B-W8A8 ]] || { echo "!! 模型目录不存在"; exit 15; }

  echo "-- 关键默认值 --"
  grep -nE '^(PREFIX|MODEL_PATH|GPU_LIST|GPUS_PER_INSTANCE|PORT|NUM_PROMPTS|NUM_WARMUPS|MAX_CONCURRENCY|CPU_RANGE|IXSYS_TRACE|PROFILE)=' \
      "$IX_SH" "$TL_SH" | head -30

  # ================= 1. 生成并启动驱动 =================
  ROOT="/home/qch/1126analysis/$(date +%Y%m%d-%H%M%S)_e2e_traces"
  mkdir -p "$ROOT/timeline" "$ROOT/ixsys"
  export ROOT
  DRIVER="$ROOT/driver.sh"
  cat > "$DRIVER" <<'DRIVER_EOF'
#!/usr/bin/env bash
# 由 203/cmd.sh 生成。四个 case 逐个起服务，避免 profiler 输出混在同一目录。
set -uo pipefail
ROOT="${ROOT:?}"
CT=corex5-py311
TK=/home/qch/scripts/litehost_perf
IX="$TK/timeline_ixsys_base.sh"
TL="$TK/vllmBench_lite_base_timeline.sh"
COMMON=(-e "PREFIX=/opt/corex311" -e "NUM_PROMPTS=100" -e "NUM_WARMUPS=16"
        -e "MAX_CONCURRENCY=8" -e "CASE_INTERVAL=0" -e "CPU_RANGE=0-15,128-143"
        -e "PORT=8848" -e "HOST_TOOLKIT=$TK" -e "GPU_LIST=0,1,2,3")
CASES=("1 2048" "128 128" "1024 1024" "2048 1")
free_gb() { df -BG --output=avail /home | tail -1 | tr -dc '0-9'; }
guard() {
    local f; f=$(free_gb)
    echo "-- /home free=${f}G --"
    (( f >= 2 )) || { echo "!!!!! STOP: /home 仅剩 ${f}G，停止后续采集"; return 1; }
}

run_tl() {
    local in=$1 out=$2 cid="bs8_in${1}_out${2}"
    local work="$ROOT/.work_tl_$cid"
    mkdir -p "$work"
    printf '%s %s\n' "$in" "$out" > "$ROOT/cases_$cid.txt"
    echo
    echo "===== [$(date '+%F %T')] timeline $cid start (free $(free_gb)G) ====="
    docker exec "${COMMON[@]}" -e "TEST_ID=e2e_tl_$cid" -e "CASES_FILE=$ROOT/cases_$cid.txt" \
        -e "HOST_MEASURE=off" -e "PROFILE=1" -e "PROFILE_ACTIVE_ITERATIONS=1000" -e "MOCK_DIR=" \
        "$CT" bash -lc "cd '$work' && bash '$TL'"
    local rc=$?
    if (( rc == 0 )) && [[ -d "$work/vllmBench/e2e_tl_$cid" ]]; then
        mv "$work/vllmBench/e2e_tl_$cid" "$ROOT/timeline/$cid"
        rmdir "$work/vllmBench" "$work" 2>/dev/null || true
        echo "===== timeline $cid OK -> $ROOT/timeline/$cid ====="
    else
        echo "!!!!! timeline $cid FAILED rc=$rc（诊断保留在 $work）"
        return 1
    fi
}

run_ix() {
    local in=$1 out=$2 cid="bs8_in${1}_out${2}"
    local work="$ROOT/.work_ix_$cid" d l
    # 长 case 只抓一段稳态窗口（defer 足够越过启动，limit 限体积）；
    # 短 case 抓全量（203 上 128/128 全量约 0.67G，2048/1 与此同量级）。
    case "$in $out" in
        "1 2048"|"1024 1024") d=200; l=40 ;;
        *)                    d=0;   l=0  ;;
    esac
    mkdir -p "$work"
    printf '%s %s\n' "$in" "$out" > "$ROOT/cases_$cid.txt"
    echo
    echo "===== [$(date '+%F %T')] ixsys $cid start (defer=${d}s limit=${l}s, free $(free_gb)G) ====="
    docker exec "${COMMON[@]}" -e "TEST_ID=e2e_ix_$cid" -e "CASES_FILE=$ROOT/cases_$cid.txt" \
        -e "HOST_MEASURE=off" -e "IXSYS_DEFER=$d" -e "IXSYS_LIMIT=$l" \
        "$CT" bash -lc "cd '$work' && bash '$IX'"
    local rc=$?
    if (( rc == 0 )) && [[ -d "$work/vllmBench/e2e_ix_$cid" ]]; then
        mv "$work/vllmBench/e2e_ix_$cid" "$ROOT/ixsys/$cid"
        rmdir "$work/vllmBench" "$work" 2>/dev/null || true
        echo "===== ixsys $cid OK -> $ROOT/ixsys/$cid ====="
    else
        echo "!!!!! ixsys $cid FAILED rc=$rc（诊断保留在 $work）"
        return 1
    fi
}

echo "ROOT=$ROOT"
echo "CASES: ${CASES[*]}"
for c in "${CASES[@]}"; do
    read -r i o <<< "$c"
    guard || exit 30
    run_tl "$i" "$o" || exit 31
    sleep 10
done
for c in "${CASES[@]}"; do
    read -r i o <<< "$c"
    guard || exit 30
    run_ix "$i" "$o" || exit 32
    sleep 10
done

echo
echo "========== 汇总 =========="
for kind in timeline ixsys; do
    for c in "${CASES[@]}"; do
        read -r i o <<< "$c"
        cid="bs8_in${i}_out${o}"
        d="$ROOT/$kind/$cid"
        [[ -d "$d" ]] || continue
        echo "-- $kind/$cid --"
        find "$d" -type f \( -name '*.json.gz' -o -name '*.json' -o -name '*.ptrace' \) \
            -printf '%10s  %p\n' 2>/dev/null | sort -k2
        [[ -f "$d/summary.csv" ]] && tail -n +2 "$d/summary.csv" | cut -d, -f1-9
    done
done
df -h /home | tail -1
echo "DRIVER_DONE_1126_E2E_TRACES"
DRIVER_EOF
  chmod +x "$DRIVER"
  echo
  echo "== 1. 启动驱动（后台，setsid 防断连） =="
  echo "ROOT=$ROOT"
  echo "CASES: 1 2048 | 128 128 | 1024 1024 | 2048 1"
  setsid nohup bash "$DRIVER" > "$ROOT/driver.log" 2>&1 &
  DPID=$!
  echo "$DPID" > "$ROOT/driver.pid"
  echo "driver pid=$DPID  log=$ROOT/driver.log"

  # ================= 2. 等待并汇报 =================
  echo
  echo "== 2. 等待驱动（最多 2 小时，每 30s 打一行） =="
  for _ in $(seq 1 240); do
      sleep 30
      if ! kill -0 "$DPID" 2>/dev/null; then break; fi
      echo "[$(date +%T)] alive; free=$(df -BG --output=avail /home | tail -1 | tr -dc '0-9')G"
  done
  if kill -0 "$DPID" 2>/dev/null; then
      echo "!! 2 小时后驱动仍在跑（pid=$DPID）。不要 kill，稍后再看 $ROOT/driver.log"
      rc=99
  else
      wait "$DPID" 2>/dev/null
      rc=$?
  fi
  echo
  echo "== 3. 结果 =="
  echo "driver rc=$rc"
  tail -n 60 "$ROOT/driver.log"
  echo
  echo "-- trace 体积 --"
  find "$ROOT" -type f \( -name '*.ptrace' -o -name '*.json.gz' -o -name '*.json' \) \
      -printf '%10s  %p\n' 2>/dev/null | sort -k2
  df -h /home | tail -1
  grep -q 'DRIVER_DONE_1126_E2E_TRACES' "$ROOT/driver.log" \
      && echo "### driver 完成" || echo "### !! driver 未完成，看 $ROOT/driver.log"

  # ---- 命令结束 ----

} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
