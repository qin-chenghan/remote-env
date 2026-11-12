#!/usr/bin/env python3
"""扫描 /home 下所有 vllmBench_lite*.sh，逐文件检查 184 相关配置。

检查项（n/a = 该文件没有这一项，不算错）：
  CPU_RANGE   期望 80-159,240-319（GPU0/1 node1，GPU2/3 node3）
  tcmalloc    若出现 libtcmalloc，期望 /home/lw/gperftools/.libs/libtcmalloc.so
  MODEL_PATH  若设置，期望 /home/model/Qwen3-32B-W8A8
  PYTHONPATH  若出现，期望 ="$HOST_TOOLKIT"（不得拼 ${PYTHONPATH:+...}）
  CLEAN_ENV   若存在，需包含 PYTHONPATH 的 unset
"""
import os
import re

EXPECT_CPU = "80-159,240-319"
EXPECT_TCM = "/home/lw/gperftools/.libs/libtcmalloc.so"
EXPECT_MODEL = "/home/model/Qwen3-32B-W8A8"

VAR_RE = r'^{key}="\${{{key}:?-?([^}}]*)\}}"'
SKIP_DIRS = ("/.git", "/docker/")


def find_files():
    hits = []
    for dirpath, dirnames, filenames in os.walk("/home"):
        if any(s in dirpath for s in SKIP_DIRS) or dirpath.count(os.sep) > 6:
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
    m = re.search(VAR_RE.format(key=key), text, re.M)
    return m.group(1).strip() if m else None


def check_cpu(t):
    v = value_of(t, "CPU_RANGE")
    if v is None:
        return "n/a"
    return "OK" if v == EXPECT_CPU else "'" + v + "'"


def check_tcm(t):
    if "libtcmalloc" not in t:
        return "none"
    if EXPECT_TCM in t:
        return "OK"
    m = re.search(r"libtcmalloc[^\s\"';]*", t)
    return "WRONG:" + (m.group(0) if m else "?")


def check_model(t):
    v = value_of(t, "MODEL_PATH")
    if v is None:
        return "n/a"
    return "OK" if v == EXPECT_MODEL else "WRONG:'" + v + "'"


def check_py(t):
    if re.search(r'PYTHONPATH="\$\{HOST_TOOLKIT\}\$\{PYTHONPATH', t):
        return "POLLUTED"
    if 'PYTHONPATH="$HOST_TOOLKIT"' in t:
        return "OK"
    return "n/a"


def check_clean(t):
    m = re.search(r"CLEAN_ENV=\(env(.+?)\)", t, re.S)
    if not m:
        return "none"
    return "OK" if "PYTHONPATH" in m.group(1) else "MISSING"


def main():
    files = find_files()
    print(f"共 {len(files)} 个文件\n")
    print(f"{'status':6s} {'CPU_RANGE':22s} {'tcmalloc':16s} {'model':10s} {'PYTHONPATH':10s} {'CLEAN_ENV':8s}  file")
    print("-" * 130)
    bad = []
    for p in files:
        try:
            t = open(p, encoding="utf-8", errors="replace").read()
        except OSError as e:
            print(f"READERR {p}: {e}")
            continue
        cpu, tc, model, py, ce = check_cpu(t), check_tcm(t), check_model(t), check_py(t), check_clean(t)
        is_bad = (
            cpu not in ("OK", "n/a")
            or tc.startswith("WRONG")
            or model.startswith("WRONG")
            or py == "POLLUTED"
            or ce == "MISSING"
        )
        status = "BAD" if is_bad else "ok"
        if is_bad:
            bad.append(p)
        print(f"{status:6s} {cpu:22s} {tc:16s} {model:10s} {py:10s} {ce:8s}  {p}")
    print(f"\n需要修正: {len(bad)}")
    for p in bad:
        print("  ❌", p)


if __name__ == "__main__":
    main()
