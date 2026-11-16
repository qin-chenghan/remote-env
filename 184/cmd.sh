#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 184：比较运行中 iluvatar 与磁盘 .ko 的 srcversion；默认只读，FIX=1 才重载模块。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

KREL=$(uname -r)
MODDIR=/lib/modules/"$KREL"/updates
FIX=${FIX:-0}
FAIL=0

{
    echo "### server: $SERVER"
    echo "### host:   $(hostname)"
    echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "### mode:   FIX=$FIX"
    echo
    set -x

    # ---- 命令开始 ----
    echo "== 0. 状态 =="
    uname -r
    echo "PAGESIZE=$(getconf PAGESIZE)"
    REF=$(awk '$1=="iluvatar"{print $3}' /proc/modules)
    echo "refcount=${REF:-not-loaded}"
    ls -l "$MODDIR"/iluvatar.ko* 2>&1

    LOADED_SRC=$(cat /sys/module/iluvatar/srcversion 2>/dev/null || true)
    DISK_SRC=$(modinfo -F srcversion "$MODDIR"/iluvatar.ko* 2>/dev/null || true)
    echo "loaded srcversion: ${LOADED_SRC:-unavailable}"
    echo "disk   srcversion: ${DISK_SRC:-unavailable}"
    if [[ -n "$LOADED_SRC" && -n "$DISK_SRC" ]]; then
        if [[ "$LOADED_SRC" == "$DISK_SRC" ]]; then
            echo "SRCVER: same"
        else
            echo "SRCVER: DIFFERENT"
        fi
    else
        echo "SRCVER: 无法比较（sysfs 或 modinfo 拿不到）"
    fi

    echo "== 1. 占用预检 =="
    fuser -v /dev/iluvatar* 2>&1 || echo "fuser: 没有进程占用（或 fuser 不可用）"
    pgrep -af 'vllm|bench_driver|lhctl|LightHostWorker' || echo "没有 vllm/bench 进程"
    timeout 20 /usr/local/corex-5.0.0/bin/ixsmi > /tmp/ixsmi.$$ 2>&1
    echo "ixsmi rc=$?"
    head -20 /tmp/ixsmi.$$
    dmesg 2>/dev/null | grep -i iluvatar | tail -6

    if [[ $FIX != 1 ]]; then
        echo "== 只读：未重载（要换内存镜像：FIX=1 bash 184/cmd.sh） =="
    else
        echo "== 2. 预检门禁 =="
        if [[ "${REF:-none}" != 0 ]]; then
            echo "STOP: refcount=${REF:-none}"
            FAIL=1
        fi
        if fuser /dev/iluvatar* >/dev/null 2>&1; then
            echo "STOP: /dev/iluvatar* 有进程占用"
            FAIL=1
        fi
        if pgrep -f 'vllm|bench_driver|lhctl|LightHostWorker' >/dev/null; then
            echo "STOP: 有 vllm/bench 进程在跑"
            FAIL=1
        fi

        if [[ $FAIL == 0 ]]; then
            echo "== 3. 重载模块 =="
            modprobe -r iluvatar; echo "rmmod rc=$?"
            sleep 1
            modprobe iluvatar; echo "modprobe rc=$?"
            sleep 3
        fi

        echo "== 4. 验证 =="
        awk '$1=="iluvatar"{print}' /proc/modules
        ls -l /dev/iluvatar* 2>&1
        timeout 20 /usr/local/corex-5.0.0/bin/ixsmi > /tmp/ixsmi.$$ 2>&1
        echo "ixsmi rc=$?"
        head -20 /tmp/ixsmi.$$
        echo "loaded srcversion now: $(cat /sys/module/iluvatar/srcversion 2>/dev/null)"
        dmesg 2>/dev/null | grep -i iluvatar | tail -8
    fi

    rm -f /tmp/ixsmi.$$
    # ---- 命令结束 ----

    set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
