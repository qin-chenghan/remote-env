#!/usr/bin/env python3
"""把 184 上 vllmBench_lite*.sh 里从 32 复制来的 CPU_RANGE=192-255 改为 184 的配置。

- 只改 CPU_RANGE，不动其它内容
- 备份为 <file>.bak-cpu-range-<ts>
- 幂等：已经是 80-159,240-319 的跳过
- 改完逐个 bash -n 校验
- 跳过 *optbak* 备份目录（如需处理请显式加 --include-backups）
"""
import os
import re
import shutil
import subprocess
import sys
import time

NEW_LINE = 'CPU_RANGE="${CPU_RANGE-80-159,240-319}"'
OLD_PAT = re.compile(r'^CPU_RANGE="\$\{CPU_RANGE[:\-]192-255\}"', re.M)
NEW_PAT = re.compile(r'^CPU_RANGE="\$\{CPU_RANGE[:\-]80-159,240-319\}"', re.M)
TS = time.strftime("%Y%m%d-%H%M%S")
include_backups = "--include-backups" in sys.argv


def scan():
    out = []
    for dirpath, dirnames, filenames in os.walk("/home"):
        if any(s in dirpath for s in ("/.git", "/docker/")):
            dirnames[:] = []
            continue
        if dirpath.count(os.sep) > 6:
            dirnames[:] = []
            continue
        for name in filenames:
            if not (name.startswith("vllmBench_lite") and name.endswith(".sh")):
                continue
            p = os.path.join(dirpath, name)
            try:
                t = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if OLD_PAT.search(t):
                out.append((p, t))
    return out


def main():
    patched, skipped_backup, already, failed = [], [], [], []
    for p, t in scan():
        if "optbak" in p and not include_backups:
            skipped_backup.append(p)
            continue
        if NEW_PAT.search(t):
            already.append(p)
            continue
        new = OLD_PAT.sub(NEW_LINE, t, count=1)
        bak = f"{p}.bak-cpu-range-{TS}"
        try:
            shutil.copy2(p, bak)
            open(p, "w", encoding="utf-8").write(new)
        except OSError as e:
            failed.append((p, str(e)))
            continue
        r = subprocess.run(["bash", "-n", p], capture_output=True, text=True)
        if r.returncode != 0:
            shutil.copy2(bak, p)   # 回滚
            failed.append((p, "bash -n 失败，已回滚: " + r.stderr.strip()[:80]))
        else:
            patched.append(p)

    print(f"已修改 {len(patched)} 个文件（备份后缀 .bak-cpu-range-{TS}）")
    for p in patched:
        print("  ✅", p)
    if already:
        print(f"\n已经是正确值（跳过）{len(already)} 个")
        for p in already:
            print("  –", p)
    if skipped_backup:
        print(f"\n备份目录（跳过，加 --include-backups 可处理）{len(skipped_backup)} 个")
        for p in skipped_backup:
            print("  –", p)
    if failed:
        print(f"\n失败 {len(failed)} 个")
        for p, e in failed:
            print("  ❌", p, e)


if __name__ == "__main__":
    main()
