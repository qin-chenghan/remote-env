#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 184 切 sp3 内核后：给当前内核重建并加载 iluvatar 驱动（DKMS 路径）。
# 只动 dkms 与模块；已加载模块不卸载、不重启。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

KREL=$(uname -r)
FAIL=0

{
    echo "### server: $SERVER"
    echo "### host:   $(hostname)"
    echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    set -x

    # ---- 命令开始 ----
    echo "== 0. 内核与系统 =="
    uname -a
    echo "PAGESIZE=$(getconf PAGESIZE)"
    sed -n '1,4p' /etc/os-release
    grubby --default-kernel 2>/dev/null
    grub2-editenv list 2>/dev/null
    df -h / | tail -1

    echo "== 1. 驱动现状 =="
    LOADED=0
    lsmod | grep -q '^iluvatar' && LOADED=1
    echo "LOADED=$LOADED"
    lsmod | grep '^iluvatar' || echo "iluvatar: not loaded"
    ls -l /dev/iluvatar* 2>&1 | head
    timeout 20 /usr/local/corex-5.0.0/bin/ixsmi > /tmp/ixsmi.$$ 2>&1
    echo "ixsmi rc=$?"
    head -20 /tmp/ixsmi.$$
    dmesg 2>/dev/null | grep -i iluvatar | tail -12

    echo "== 2. DKMS / 源码 / 头文件 =="
    command -v dkms || echo "dkms: not installed"
    dkms status 2>&1
    ls -d /usr/src/corex-* 2>&1
    ls -d /var/lib/dkms/corex/* 2>&1 | head
    grep -n '_BUILDOPT\|VGPU_ENABLE' /usr/src/corex-5.0.0/dkms.conf 2>&1
    ls -d /usr/src/kernels/* 2>&1
    ls -l /lib/modules/"$KREL"/build 2>&1
    ls -l /lib/modules/"$KREL"/updates/ 2>&1 | head
    modinfo -F vermagic /lib/modules/"$KREL"/updates/iluvatar.ko* 2>&1

    WORKING=0
    if [[ $LOADED == 1 && -e /dev/iluvatar0 ]]; then
        timeout 20 /usr/local/corex-5.0.0/bin/ixsmi >/dev/null 2>&1 && WORKING=1
    fi
    echo "WORKING=$WORKING"

    if [[ $WORKING == 1 ]]; then
        echo "== 驱动已可用，跳过构建 =="
    elif [[ $LOADED == 1 ]]; then
        echo "== 模块已加载但不可用：不自动卸载/重装，保留现场 =="
        dmesg 2>/dev/null | grep -i iluvatar | tail -20
    else
        echo "== 3. 源码与头文件检查 =="
        SRC=/usr/src/corex-5.0.0
        if [[ ! -f "$SRC/dkms.conf" ]]; then
            echo "STOP: $SRC/dkms.conf 不存在"
            ls -l /home/qch/transfer/*corex*5.0.0* 2>/dev/null | head
            FAIL=2
        fi

        if [[ $FAIL == 0 ]]; then
            if [[ -d /usr/src/kernels/"$KREL" && -e /lib/modules/"$KREL"/build ]]; then
                echo "kernel-devel present: $KREL"
            else
                echo "exact kernel-devel missing: $KREL"
                dnf -q list --showduplicates kernel-devel 2>/dev/null | grep -F "$KREL" | head -5
                if dnf -q list kernel-devel-"$KREL" >/dev/null 2>&1; then
                    dnf install -y --setopt=install_weak_deps=False kernel-devel-"$KREL"
                else
                    RPM=$(find /home/l30029702/64k /home/qch/transfer -maxdepth 2 \
                        -name "kernel-devel-*${KREL}*.rpm" 2>/dev/null | head -1)
                    echo "local rpm: ${RPM:-none}"
                    if [[ -n "$RPM" ]]; then
                        dnf install -y "$RPM"
                    else
                        echo "STOP: 没有 $KREL 的 kernel-devel（dnf 与本地 rpm 都没有）"
                        FAIL=3
                    fi
                fi
            fi
        fi

        if [[ $FAIL == 0 && ! -e /lib/modules/"$KREL"/build ]]; then
            echo "STOP: /lib/modules/$KREL/build 仍不存在"
            FAIL=3
        fi

        if [[ $FAIL == 0 ]]; then
            echo "== 4. VGPU_ENABLE=0（源目录） =="
            CONF="$SRC/dkms.conf"
            grep -n VGPU_ENABLE "$CONF"
            if grep -q 'VGPU_ENABLE=1' "$CONF"; then
                cp -a "$CONF" "$CONF.bak-$TS"
                sed -i 's/VGPU_ENABLE=1/VGPU_ENABLE=0/g' "$CONF"
                echo "VGPU_ENABLE set to 0"
            fi
            grep -n VGPU_ENABLE "$CONF"

            echo "== 5. dkms build / install =="
            dkms build --force corex/5.0.0 -k "$KREL" || FAIL=4
            if [[ $FAIL == 0 ]]; then
                dkms install --force corex/5.0.0 -k "$KREL" || FAIL=5
            fi

            if [[ $FAIL == 0 ]]; then
                echo "== 6. depmod + modprobe =="
                depmod -a "$KREL"
                modprobe iluvatar; echo "modprobe rc=$?"
                sleep 3
            fi
        fi

        echo "== 7. 验证 =="
        lsmod | grep '^iluvatar' || echo "iluvatar: not loaded"
        ls -l /dev/iluvatar* 2>&1 | head
        timeout 20 /usr/local/corex-5.0.0/bin/ixsmi > /tmp/ixsmi.$$ 2>&1
        echo "ixsmi rc=$?"
        head -20 /tmp/ixsmi.$$
        dmesg 2>/dev/null | grep -i iluvatar | tail -15
        dkms status 2>&1

        if [[ $FAIL != 0 ]]; then
            echo "== 8. 失败现场 =="
            echo "FAIL=$FAIL"
            find /var/lib/dkms/corex/5.0.0 -name 'make.log' 2>/dev/null | head -3
            for f in $(find /var/lib/dkms/corex/5.0.0 -name 'make.log' 2>/dev/null | head -1); do
                echo "-- $f"
                tail -60 "$f"
            done
        fi
    fi

    rm -f /tmp/ixsmi.$$
    # ---- 命令结束 ----

    set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
