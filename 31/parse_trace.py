import collections, json, os, sys

path = sys.argv[1]
print("file=%s size=%.1f MB" % (path, os.path.getsize(path) / 1048576))
if path.endswith(".gz"):
    import gzip
    fh = gzip.open(path, "rt")
else:
    fh = open(path)
d = json.load(fh)
fh.close()
events = d.get("traceEvents", d) if isinstance(d, dict) else d
d = None
print("events=%d" % len(events))

HOST_CATS = {"cpu_op", "cuda_runtime", "cuda_driver", "python_function",
             "user_annotation"}
GPU_COPY_CATS = {"gpu_memcpy", "gpu_memset"}

cats = collections.Counter()
cat_dur = collections.Counter()
cat_sample = {}
kern = []
copy = []
host = collections.defaultdict(list)
sync_iv = []
sync = collections.Counter()
sync_dur = collections.Counter()
kern_by_name = collections.Counter()
span_lo = span_hi = None

for ev in events:
    if ev.get("ph") != "X":
        continue
    ts = ev.get("ts")
    dur = ev.get("dur")
    if ts is None or dur is None:
        continue
    lo, hi = ts, ts + dur
    span_lo = lo if span_lo is None or lo < span_lo else span_lo
    span_hi = hi if span_hi is None or hi > span_hi else span_hi
    cat = ev.get("cat", "")
    name = ev.get("name", "?")
    cats[cat] += 1
    cat_dur[cat] += dur
    cat_sample.setdefault(cat, name)
    if cat == "kernel":
        kern.append((ts, hi))
        kern_by_name[name] += dur
    elif cat in GPU_COPY_CATS:
        copy.append((ts, hi))
    elif cat in HOST_CATS:
        host[ev.get("tid")].append((ts, hi))
    if "synchronize" in name.lower():
        sync[name] += 1
        sync_dur[name] += dur
        sync_iv.append((ts, hi))

print("-- categories (top 12) --")
for c, n in cats.most_common(12):
    print("  %-22s n=%-9d dur=%.3f s   e.g. %s"
          % (c or "(none)", n, cat_dur[c] / 1e6, cat_sample[c][:60]))


def merge(iv):
    iv = sorted(iv)
    out = []
    for a, b in iv:
        if out and a <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def total_len(iv):
    return sum(b - a for a, b in iv)


def complement(iv, lo, hi):
    out = []
    cur = lo
    for a, b in merge(iv):
        if a > cur:
            out.append((cur, a))
        cur = max(cur, b)
    if cur < hi:
        out.append((cur, hi))
    return out


def intersect(x, y):
    x, y = merge(x), merge(y)
    out = []
    i = j = 0
    while i < len(x) and j < len(y):
        a = max(x[i][0], y[j][0])
        b = min(x[i][1], y[j][1])
        if a < b:
            out.append((a, b))
        if x[i][1] < y[j][1]:
            i += 1
        else:
            j += 1
    return out


span = span_hi - span_lo
print("span=%.3f s" % (span / 1e6))

main_tid = max(host, key=lambda t: len(host[t]))
cpu_busy = merge(host[main_tid])
cpu_idle = complement(cpu_busy, span_lo, span_hi)
host_all = merge([iv for t in host for iv in host[t]])

print("-- host threads: %d, main tid=%s (%d events) --"
      % (len(host), main_tid, len(host[main_tid])))
print("  CPU busy(main)=%.3f s (%.1f%%)  idle=%.3f s (%.1f%%)"
      % (total_len(cpu_busy) / 1e6, 100 * total_len(cpu_busy) / span,
         total_len(cpu_idle) / 1e6, 100 * total_len(cpu_idle) / span))
print("  CPU busy(all threads)=%.3f s (%.1f%%)"
      % (total_len(host_all) / 1e6, 100 * total_len(host_all) / span))


def report(label, gpu_busy):
    gpu_idle = complement(gpu_busy, span_lo, span_hi)
    print("-- %s --" % label)
    print("  GPU busy=%.3f s (%.1f%%)  idle=%.3f s (%.1f%%)"
          % (total_len(gpu_busy) / 1e6, 100 * total_len(gpu_busy) / span,
             total_len(gpu_idle) / 1e6, 100 * total_len(gpu_idle) / span))
    gb_cb = total_len(intersect(gpu_busy, cpu_busy))
    gb_ci = total_len(intersect(gpu_busy, cpu_idle))
    gi_cb = total_len(intersect(gpu_idle, cpu_busy))
    gi_ci = total_len(intersect(gpu_idle, cpu_idle))
    print("  GPU busy & CPU busy  %.3f s (%.1f%%)" % (gb_cb / 1e6, 100 * gb_cb / span))
    print("  GPU busy & CPU idle  %.3f s (%.1f%%)" % (gb_ci / 1e6, 100 * gb_ci / span))
    print("  GPU idle & CPU busy  %.3f s (%.1f%%)" % (gi_cb / 1e6, 100 * gi_cb / span))
    print("  GPU idle & CPU idle  %.3f s (%.1f%%)" % (gi_ci / 1e6, 100 * gi_ci / span))
    print("  sync during GPU idle=%.3f s"
          % (total_len(intersect(sync_iv, gpu_idle)) / 1e6))


report("GPU busy = kernels only", merge(kern))
report("GPU busy = kernels + memcpy/memset", merge(kern + copy))

print("-- GPU kernels: %d, total dur %.3f s --"
      % (len(kern), sum(kern_by_name.values()) / 1e6))
ksum = sum(kern_by_name.values())
for name, dur in kern_by_name.most_common(10):
    print("  %-58s %.3f s (%5.1f%%)" % (name[:58], dur / 1e6, 100 * dur / ksum))

print("-- synchronize calls --")
for n, c in sync.most_common(6):
    print("  %-38s n=%-7d total=%.3f s avg=%.3f ms"
          % (n[:38], c, sync_dur[n] / 1e6, sync_dur[n] / c / 1000))
