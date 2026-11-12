#!/usr/bin/env python3
"""扫描 /home 下所有 vllmBench_lite*.sh，逐文件检查 184 相关配置。

检查项：
  CPU_RANGE   期望 80-159,240-319（GPU0/1 在 node1，GPU2/3 在 node3）
  tcmalloc    期望 /home/lw/gperftools/.libs/libtcmalloc.so（32 的路径不可用）
  MODEL_PATH  期望 /home/model/Qwen3-32B-W8A8（/home/model/ts 在 184 不存在）
  PYTHONPATH  期望 ="$HOST_TOOLKIT"（不得再拼继承值）
  CLEAN_ENV   需含 -u PYTHONPATH -u PYTHONHOME
"""
import os
import re
import sys

EXPECT_CPU = "80-159,240-319"
EXPECT_TCM = "/home/lw/gperftools/.libs/libtcmalloc.so"
EXPECT_MODEL = "/home/model/Qwen3-32B-W8A8"

ROOTS = ["/home"]
SKIP_DIRS = ("/.git", "/docker/")


def find_files():
    hits = []
    for root in ROOTS:
        for dirpath, dirnames, filenames in os.walk(root):
            if any(s in dirpath for s in SKIP_DIRS):
                dirnames[:] = []
                continue
            if dirpath.count(os.sep) > 6:
                dirnames[:] = []
                continue
            for name in filenames:
                if name.startswith("vllmBench_lite") and name.endswith(".sh"):
                    p = os.path.join(dirpath, name)
                    try:
                        hits.append((os.path.getmtime(p), p))
                    except OSError:
                        pass
    return [p for _, p in sorted(hits, reverse=True)]


def value_of(text, key):
    m = re.search(rf'^{key}="\$\{{{key}[:\-]([^}}]*)\}}"', text, re.M)
    return m.group(1) if m else None


def main():
    files = find_files()
    print(f"共 {len(files)} 个文件\n")
    hdr = f"{'status':6s} {'CPU_RANGE':16s} {'tcmalloc':10s} {'model':9s} {'PYTHONPATH':10s} {'CLEAN_ENV':9s}  file"
    print(hdr)
    print("-" * len(hdr))
    bad = []
    for p in files:
        try:
            t = open(p, encoding="utf-8", errors="replace").read()
        except OSError as e:
            print(f"READERR {p}: {e}")
            continue
        cpu = value_of(t, "CPU_RANGE")
        tc = "OK" if EXPECT_TCM in t else ("MISS" if "libtcmalloc" in t else "-")
        if "libtcmalloc" in t and EXPECT_TCM not in t:
            m = re.search(r"libtcmalloc[^\s\"':]*", t)
            tc = "WRONG" if m else tc
        model = value_of(t, "MODEL_PATH")
        model_ok = "OK" if model == EXPECT_MODEL else ("UNSET" if model is None else "WRONG")
        py = "OK" if 'PYTHONPATH="$HOST_TOOLKIT"' in t else "WRONG"
        ce = "OK" if re.search(r"CLEAN_ENV=\(env[^\n]*\n[^\n]*PYTHONPATH", t) else "WRONG"
        cpu_ok = "OK" if cpu == EXPECT_CPU else ("UNSET" if cpu is None else "WRONG")
        bad_flag = any(x in ("WRONG", "UNSET") for x in (cpu_ok, model_ok, py, ce)) or tc == "WRONG"
        status = "BAD" if bad_flag else "ok"
        if bad_flag:
            bad.append(p)
        print(f"{status:6s} {str(cpu)[:16]:16s} {tc:10s} {model_ok:9s} {py:10s} {ce:9s}  {p}")
    print(f"\n需要修正: {len(bad)}")
    for p in bad:
        print("  ❌", p)


if __name__ == "__main__":
    main()
