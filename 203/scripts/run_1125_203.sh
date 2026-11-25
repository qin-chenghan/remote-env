#!/usr/bin/env bash
# 203 三份 128/128 基线数据顺序采集（vllmBench lite / ixsys / torch profiler，仅 base）。
# 必须在容器内执行：
#   docker exec corex5-py311 bash -lc 'cd /home/qch/scripts/litehost_perf && bash run_1125_203.sh'
# 结果目录：/home/qch/1125analysis/{vllm_base,ixsys_base,timeline_base}
set -uo pipefail

SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-/home/qch/1125analysis}"
PREFIX_BASE="${PREFIX_BASE:-/opt/corex311}"
MIN_FREE_GB="${MIN_FREE_GB:-3}"
LOG="${ROOT}/driver.log"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "ABORT: $*"; touch "${ROOT}/DRIVER_FAILED_1125"; exit 1; }

mkdir -p "$ROOT"
rm -f "${ROOT}/DRIVER_DONE_1125" "${ROOT}/DRIVER_FAILED_1125"

# ---------------- 前置检查（只读） ----------------
log "==== preflight ===="
log "host=$(uname -m) kernel=$(uname -r) cpus=$(nproc)"
for f in procutil.py lhctl.py bench_driver.py light_host_worker.py analyze_litehost.py liblitehost.so; do
    [[ -f "$SCRIPTS_DIR/$f" ]] || die "工具包缺 $SCRIPTS_DIR/$f"
done
log "liblitehost: $(file -b "$SCRIPTS_DIR/liblitehost.so" 2>/dev/null | cut -d, -f1-2)"
[[ -x "$PREFIX_BASE/bin/python3" ]] || die "缺 venv: $PREFIX_BASE"
[[ -x /usr/local/corex/bin/ixsys ]] || die "缺 ixsys: /usr/local/corex/bin/ixsys"
[[ -f /home/hc/modules/Qwen3-32B-W8A8/config.json ]] || die "模型目录不可见: /home/hc/modules/Qwen3-32B-W8A8"

free_gb=$(df -BG --output=avail /home | tail -1 | tr -dc '0-9')
log "/home 可用: ${free_gb}G（要求 >= ${MIN_FREE_GB}G；三份约 900M）"
(( free_gb >= MIN_FREE_GB )) || die "/home 空间不足，先清理"

log "itr_multi_compute_engine=$(cat /sys/module/iluvatar/parameters/itr_multi_compute_engine 2>/dev/null || echo unknown)"
pgrep -af 'vllm.entrypoints.openai.api_server' >/dev/null 2>&1 && die "已有 vllm 服务在跑，先停掉"
pgrep -af '[/]usr/local/corex/bin/ixsys' >/dev/null 2>&1 && die "已有 ixsys 进程在跑，先停掉"

for name in vllm_base ixsys_base timeline_base; do
    [[ -e "$ROOT/$name" ]] && die "结果目录已存在: $ROOT/$name（换 ROOT 或先移走）"
    [[ -e "$ROOT/.work_$name" ]] && die "残留工作目录: $ROOT/.work_$name（先移走再跑）"
done

# ---------------- 顺序跑三份 ----------------
run_one() {
    local name="$1" script="$2" tid="$3"
    local work="$ROOT/.work_$name"
    log "START $name | TEST_ID=$tid | script=$script"
    mkdir -p "$work"
    if ( cd "$work" && env TEST_ID="$tid" PREFIX="$PREFIX_BASE" HOST_TOOLKIT="$SCRIPTS_DIR" \
            bash "$SCRIPTS_DIR/$script" ) >> "$LOG" 2>&1; then
        [[ -d "$work/vllmBench/$tid" ]] || die "$name 完成但找不到 $work/vllmBench/$tid"
        mv "$work/vllmBench/$tid" "$ROOT/$name" || die "$name 移动失败"
        rmdir "$work/vllmBench" "$work" 2>/dev/null || true
        log "DONE $name -> $ROOT/$name"
    else
        local rc=$?
        log "FAIL $name rc=$rc（诊断保留在 $work）"
        touch "${ROOT}/DRIVER_FAILED_1125"
        return 1
    fi
}

run_one vllm_base     vllmBench_lite_base.sh         vllmBase_1125     || exit 1
run_one ixsys_base    timeline_ixsys_base.sh         vllmBase_ixsys_1125 || exit 1
run_one timeline_base vllmBench_lite_base_timeline.sh timelineBase_1125 || exit 1

log "==== 三份全部完成 ===="
touch "${ROOT}/DRIVER_DONE_1125"
