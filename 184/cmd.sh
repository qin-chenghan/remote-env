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
  set -x

  # ---- 命令开始 ----
  # 第十二批（重推）：改两个 bench 脚本，去掉 rebase 切换逻辑，改静态 venv + 只读断言。
  # 有 bench/vllm 进程在跑就中止。改前备份，改后 bash -n + diff。

  D=/home/huawei_ts_program/litehost_perf_opt

  echo "== 0. 占用检查（有则中止）=="
  BUSY=$(pgrep -af "vllmBench|bench_driver|vllm.entrypoints|api_server" 2>/dev/null | grep -v "pgrep\|cmd.sh" || true)
  if [ -n "$BUSY" ]; then
    echo "ABORT: 有任务在跑："
    echo "$BUSY" | head -10
    exit 1
  fi
  echo "无 bench/vllm 进程"
  echo "-- 快速看 GPU --"
  docker exec corex5-py311 sh -c 'ixsmi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader 2>/dev/null | head -8 || echo ixsmi-unavailable'

  echo "== 1. 备份并修改 =="
  python3 - <<'PYPATCH'
import shutil, time

D = "/home/huawei_ts_program/litehost_perf_opt"
TS = time.strftime("%Y%m%d-%H%M%S")

CLEANUP_BASE = '''    if [[ "$PGO_RESTORE" == 1 ]]; then
        log "恢复跑之前的 PGO 运行时"
        if pgo_switch; then
            :
        elif pgo_is_on; then
            log "NOTE: switch 报校验提示，但运行时已是 PGO（已知的 payload 变更情况，无需处理）"
        else
            log "WARNING: 未能恢复到 PGO 运行时"
            log "         下一步: /opt/corex311/bin/python3 /home/qch/scripts/pgo-doctor.py on"
            [[ -d "$RUN_DIR" ]] && date > "$RUN_DIR/PGO_RESTORE_FAILED.txt"
        fi
        PGO_RESTORE=0
    fi
'''

CLEANUP_OPT = '''    if [[ "$PGO_RESTORE" == 1 ]]; then
        log "回滚 $PGO_VENV 到原 base"
        if pgo_rollback; then
            :
        elif pgo_is_on; then
            log "WARNING: rollback 未完成，venv 仍停在 PGO"
            log "         下一步: /opt/corex311/bin/python3 /home/qch/scripts/pgo-doctor.py off"
            [[ -d "$RUN_DIR" ]] && date > "$RUN_DIR/PGO_ROLLBACK_FAILED.txt"
        else
            log "NOTE: rollback 报校验提示，但运行时已回到 base（已知的 payload 变更情况，无需处理）"
        fi
        PGO_RESTORE=0
    fi
'''

MAIN_BASE = '''if pgo_is_on; then
    log "当前是 PGO 运行时，回滚到原 base"
    if pgo_rollback; then
        PGO_RESTORE=1
        log "已回滚到原 base（结束后恢复 PGO）"
    elif pgo_is_on; then
        log "ERROR: rebase rollback 失败，无法保证在非 PGO 环境运行"
        log "       诊断: /opt/corex311/bin/python3 /home/qch/scripts/pgo-doctor.py"
        exit 3
    else
        PGO_RESTORE=1
        log "已回滚到原 base（rollback 报校验提示，但运行时已是 base；结束后恢复 PGO）"
    fi
else
    log "PGO 运行时未启用，继续使用原 base"
fi
'''

MAIN_OPT = '''if pgo_is_on; then
    log "PGO 运行时已启用，跳过 switch"
else
    if pgo_switch; then
        PGO_RESTORE=1
        log "已切换到 PGO 运行时（结束时回滚）"
    else
        log "ERROR: rebase switch 失败，无法保证在 PGO 环境运行"
        log "       诊断: /opt/corex311/bin/python3 /home/qch/scripts/pgo-doctor.py"
        exit 3
    fi
fi
'''

ASSERT_BASE = '''# base 需要非 PGO 运行时；PGO 状态由 PREFIX 指向的 venv 决定，脚本不再自动切换。
if pgo_is_on; then
    log "ERROR: base 需要非 PGO 运行时，但 $PREFIX 当前是 PGO"
    log "       先执行: /opt/corex311/bin/python3 /home/qch/scripts/pgo-doctor.py off"
    exit 3
fi
log "runtime: base（非 PGO），PREFIX=$PREFIX"
'''

ASSERT_OPT = '''# opt 需要 PGO 运行时；PGO 状态由 PREFIX 指向的 venv 决定，脚本不再自动切换。
if ! pgo_is_on; then
    log "ERROR: opt 需要 PGO 运行时，但 $PREFIX 不是 PGO"
    log "       检查 PREFIX 是否指向 /opt/corex311-cpython-vllm"
    exit 3
fi
if [[ ! -f "$PREFIX/lib/python3.11/site-packages/vllm/v1/worker/host_fastpath.py" ]]; then
    log "ERROR: $PREFIX 里的 vllm 没有 host fastpath 补丁，先安装 r3"
    exit 3
fi
log "runtime: opt（PGO + host fastpath），PREFIX=$PREFIX"
'''

HEADER_OLD = '''# ---- PGO guard: autofix two known-safe block causes, verify rollback --------
PGO_VENV=/opt/corex311
PGO_STATE=/root/.local/state/cpython-vllm-rebase
'''
HEADER_NEW = '''# ---- runtime check: read-only; PGO state is selected by the venv PREFIX points to ----
'''

def patch(path, is_base):
    src = open(path, encoding="utf-8").read()
    orig_len = len(src)

    if HEADER_OLD not in src:
        raise SystemExit(f"FAIL {path}: header block not found")
    src = src.replace(HEADER_OLD, HEADER_NEW)

    s = src.index("pgo_fix_perms() {")
    e = src.index("SERVER_PREFIX=()")
    src = src[:s] + src[e:]

    if "; PGO_RESTORE=0" not in src:
        raise SystemExit(f"FAIL {path}: PGO_RESTORE init not found")
    src = src.replace("; PGO_RESTORE=0", "")

    cleanup = CLEANUP_BASE if is_base else CLEANUP_OPT
    main = MAIN_BASE if is_base else MAIN_OPT
    assert_block = ASSERT_BASE if is_base else ASSERT_OPT
    if cleanup not in src:
        raise SystemExit(f"FAIL {path}: cleanup block not found")
    src = src.replace(cleanup, "")
    if main not in src:
        raise SystemExit(f"FAIL {path}: main flow block not found")
    src = src.replace(main, assert_block)

    if not is_base:
        old_prefix = 'PREFIX="${PREFIX:-/opt/corex311}"'
        new_prefix = 'PREFIX="${PREFIX:-/opt/corex311-cpython-vllm}"'
        if old_prefix not in src:
            raise SystemExit(f"FAIL {path}: PREFIX line not found")
        src = src.replace(old_prefix, new_prefix)

    leftover = [ln for ln in src.splitlines()
                if "PGO_RESTORE" in ln or "pgo_switch" in ln
                or "pgo_rollback" in ln or "pgo_fix_" in ln]
    if leftover:
        raise SystemExit(f"FAIL {path}: leftover switching refs: {leftover}")

    backup = f"{path}.bak-{TS}"
    shutil.copy2(path, backup)
    open(path, "w", encoding="utf-8").write(src)
    print(f"PATCHED {path} (backup {backup}, {orig_len} -> {len(src)} bytes)")

patch(f"{D}/vllmBench_lite_base.sh", True)
patch(f"{D}/vllmBench_lite_opt.sh", False)
PYPATCH

  echo "== 2. 语法检查 =="
  for f in "$D/vllmBench_lite_base.sh" "$D/vllmBench_lite_opt.sh"; do
    bash -n "$f" && echo "OK $f" || echo "SYNTAX ERROR $f"
  done

  echo "== 3. diff（旧 -> 新）=="
  for f in "$D/vllmBench_lite_base.sh" "$D/vllmBench_lite_opt.sh"; do
    echo "---- $f"
    diff -u "$f".bak-* "$f" | head -120
  done

  echo "== 4. 修改后仍引用的 pgo 相关行 =="
  grep -n "pgo_is_on\|pgo_runtime\|PGO" "$D/vllmBench_lite_base.sh" "$D/vllmBench_lite_opt.sh"

  echo "== 5. 关键默认值 =="
  grep -n "PREFIX=\|VLLM_DISABLE_DECODE_FASTPATH\|VLLM_HOST_FASTPATH\|TORCH_MODULE_ATTR" \
    "$D/vllmBench_lite_base.sh" "$D/vllmBench_lite_opt.sh"

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
