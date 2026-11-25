import sqlite3, sys, collections, statistics as st, json


def merge_len(iv):
    if not iv:
        return 0.0, 0
    iv = sorted(iv)
    tot = 0.0
    cs, ce = iv[0]
    n = 1
    for s, e in iv[1:]:
        if s > ce:
            tot += ce - cs
            cs, ce = s, e
            n += 1
        else:
            ce = max(ce, e)
    tot += ce - cs
    return tot, n


def med(xs):
    return st.median(xs) if xs else float('nan')


def run(path, ready, tag):
    db = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    t0, t1 = db.execute("select start_ts,end_ts from trace_bounds").fetchone()
    lo = t0 + int((ready + 20) * 1e9)
    hi = min(t0 + int((ready + 50) * 1e9), t1)
    N = dict(db.execute("select id,name from function_name_map"))

    graphs = db.execute(
        "select ts,dur,deviceId,processId,name_id from cuda_graph_data "
        "where ts>=? and ts<?", (lo, hi)).fetchall()
    bb_all = [g for g in graphs if g[1] > 5e6]
    devc = collections.Counter(g[2] for g in bb_all)
    if not devc:
        print("RUN %s: no backbone graphs" % tag)
        return
    dev = 3 if 3 in devc else devc.most_common(1)[0][0]
    pidc = collections.Counter(g[3] for g in bb_all if g[2] == dev)
    pid = pidc.most_common(1)[0][0]
    bb = sorted([g for g in bb_all if g[2] == dev and g[3] == pid])
    small = sorted([g for g in graphs if g[2] == dev and g[3] == pid and g[1] <= 5e6])

    kern = sorted(db.execute(
        "select ts,dur,name_id from cuda_kernel_data "
        "where deviceId=? and processId=? and ts>=? and ts<?",
        (dev, pid, lo, hi)).fetchall())

    api = collections.defaultdict(list)
    for ts, du, nid in db.execute(
            "select ts,dur,name_id from cuda_api_data where ts>=? and ts<? and processId=?",
            (lo, hi, pid)).fetchall():
        api[N.get(nid, str(nid))].append((ts, du))

    def apis(name):
        return api.get(name, [])

    sync_names = sorted(k for k in api if 'Synchronize' in k)

    kts = [k[0] for k in kern]
    import bisect
    periods, maind, taill, tailg, postidle, idles = [], [], [], [], [], []
    busy_tot = 0.0
    per_api = collections.defaultdict(lambda: [0, 0.0])
    small_n = []
    for i in range(len(bb) - 1):
        s0, d0 = bb[i][0], bb[i][1]
        s1 = bb[i + 1][0]
        per = (s1 - s0) / 1e6
        a = bisect.bisect_left(kts, s0)
        b = bisect.bisect_left(kts, s1)
        kk = kern[a:b]
        ss = [g for g in small if s0 <= g[0] < s1]
        iv = [(s0, s0 + d0)] + [(t, t + d) for t, d, _ in kk] + [(g[0], g[0] + g[1]) for g in ss]
        busy, _ = merge_len(iv)
        busy_ms = busy / 1e6
        idle = per - busy_ms
        tail_iv = [(t, t + d) for t, d, _ in kk if t >= s0 + d0] + \
                  [(g[0], g[0] + g[1]) for g in ss if g[0] >= s0 + d0]
        if tail_iv:
            tl, _ = merge_len(tail_iv)
            hull_s = min(x[0] for x in tail_iv)
            hull_e = max(x[1] for x in tail_iv)
            tail_ms = tl / 1e6
            tail_gap = (hull_e - hull_s - tl) / 1e6
            post = (s1 - hull_e) / 1e6
        else:
            tail_ms = tail_gap = post = 0.0
        periods.append(per)
        maind.append(d0 / 1e6)
        taill.append(tail_ms)
        tailg.append(tail_gap)
        postidle.append(post)
        idles.append(idle)
        busy_tot += busy
        small_n.append(len(ss))
        for name, rows in api.items():
            n = sum(1 for t, _ in rows if s0 <= t < s1)
            if n:
                per_api[name][0] += n
                per_api[name][1] += sum(d for t, d in rows if s0 <= t < s1) / 1e6

    periods = periods[2:-2]; maind = maind[2:-2]; taill = taill[2:-2]
    tailg = tailg[2:-2]; postidle = postidle[2:-2]; idles = idles[2:-2]; small_n = small_n[2:-2]
    steps = len(periods)
    win = (hi - lo) / 1e9
    print("RUN %s" % tag)
    print("  trace=%.1fs window=+%d..+%ds (%.1fs) dev=%d pid=%d" %
          ((t1 - t0) / 1e9, ready + 20, ready + 50, win, dev, pid))
    print("  steps=%d period=%.2fms busy=%.1f%% graph=%.2f tail=%.2f tailgap=%.2f postidle=%.2f idle=%.2f (ms)" %
          (steps, med(periods), 100 * busy_tot / 1e9 / win, med(maind), med(taill),
           med(tailg), med(postidle), med(idles)))
    print("  graphs: backbone=%d small/step=%.2f small_time/step=%.2fms" %
          (len(bb), med(small_n), med([sum(g[1] for g in small if s0 <= g[0] < s1) / 1e6
                                       for s0, s1 in zip([x[0] for x in bb[:-1]], [x[0] for x in bb[1:]])][2:-2]) if small else 0.0))
    print("  host api / step:")
    for name in ('cudaGraphLaunch', 'cudaLaunchKernel', 'cudaMemcpyAsync', 'cudaMemcpy',
                 'cudaStreamSynchronize', 'cudaEventSynchronize', 'cudaDeviceSynchronize'):
        if name in per_api and steps:
            n, ms = per_api[name]
            print("    %-22s n=%.2f dur=%.3fms" % (name, n / steps, ms / steps))
    for name in sync_names:
        if name not in ('cudaStreamSynchronize', 'cudaEventSynchronize', 'cudaDeviceSynchronize') \
                and name in per_api and steps:
            n, ms = per_api[name]
            print("    %-22s n=%.2f dur=%.3fms" % (name, n / steps, ms / steps))
    print("  small graphs by dur:")
    gd = collections.Counter()
    for g in small:
        gd[round(g[1] / 1e6, 2)] += 1
    for d, c in sorted(gd.items(), key=lambda kv: -kv[0])[:8]:
        print("    %.2fms x %d" % (d, c))
    byname = collections.Counter()
    for t, d, nid in kern:
        byname[N.get(nid, str(nid))] += d
    print("  out-of-graph kernels (window rows=%d, %.0f/step):" % (len(kern), len(kern) / steps))
    for n, du in byname.most_common(12):
        print("    %9.3fms total  %s" % (du / 1e9, n[:90]))


if __name__ == '__main__':
    for spec in sys.argv[1:]:
        path, ready, tag = spec.split('|')
        run(path, float(ready), tag)
