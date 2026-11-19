#!/usr/bin/env python3
"""Per-case four-rank average TOTAL H and H+G (gap-inclusive) in seconds; stdlib only.
Accept only files finalized by this compatibility package. Never infer warmup
from 1954/1692 counts; never mix multiple cases or rank PIDs into one run.
"""
from __future__ import annotations
import argparse,csv,math,statistics,sys
from pathlib import Path
from lh_common import FIELDS,NATIVE,read_json,atomic_json,digest
TEXT={'session_id','case_id','run_id','phase','scope','error'}
GROUPS=('all_formal','graph_formal','no_graph_formal')

def totals(rows,p):
    t=sum(r['total_ns'] for r in rows);s=sum(r['sync_ns'] for r in rows);h=t-s+s*p/100
    return {'iterations':len(rows),'T_total_s':t/1e9,'S_total_s':s/1e9,'H_base_total_s':(t-s)/1e9,'link_addback_s':s*p/100/1e9,'H_total_s':h/1e9,'H_ms_per_iter_aux':h/len(rows)/1e6 if rows else None,'sync_calls':sum(r['sync_calls'] for r in rows),'graph_calls':sum(r['graph_launch_calls'] for r in rows)}

def gap_total_ns(rows):
    """Gap wall time between adjacent formal Worker scopes; no outer boundary gaps.

    Rows must be ordered and non-overlapping. G is NOT CPU busy time and
    does NOT subtract any sync outside the instrumented scopes.
    """
    if not rows:return 0
    gaps=[b['start_ns']-a['end_ns'] for a,b in zip(rows,rows[1:])]
    if any(g<0 for g in gaps):raise ValueError('Overlapping formal scope gap')
    gap_ns=sum(gaps)
    if rows[-1]['end_ns']-rows[0]['start_ns']!=sum(r['total_ns'] for r in rows)+gap_ns:
        raise ValueError('Invalid scope-gap partition')
    return gap_ns

def case_report(path,p):
    case=read_json(path/'case.json');w=read_json(path/'window.json')
    if w['status']!='complete' or case.get('status')!='complete':raise ValueError(f'{path}: incomplete case/client')
    if any(w[k]!=case[k] for k in ('run_id','case_id','session_id')):raise ValueError('Client/case identity mismatch')
    n=case['expected_requests']
    if w['successful']!=n or w['failed']:raise ValueError('Formal requests did not all succeed')
    metas=[read_json(p) for p in sorted(path.glob('rank*_pid*.meta.json'))]
    if len(metas)!=4 or {m['rank'] for m in metas}!={0,1,2,3} or len({m['pid'] for m in metas})!=4:raise ValueError('Exactly ranks 0..3 / four unique PIDs required')
    if {p.name for p in path.glob('rank*_pid*.csv')}!={m['csv'] for m in metas}:raise ValueError('Stray or missing CSV')
    if len(w.get('arm_acks',[]))!=4 or len(w.get('finalize_acks',[]))!=4:raise ValueError('Missing boundary ACKs')
    if {a['rank'] for a in w['arm_acks']}!={0,1,2,3} or {a['rank'] for a in w['finalize_acks']}!={0,1,2,3}:raise ValueError('Duplicate boundary ACKs')
    ranks=[];signatures=[]
    for m in sorted(metas,key=lambda m:m['rank']):
        if m['status']!='complete' or m['errors'] or m['pending']:raise ValueError('Incomplete worker state')
        if any(m[k]!=case[k] for k in ('run_id','case_id','session_id')):raise ValueError('Mixed case/run')
        if m['native_hash']!=case['native_hash']:raise ValueError('Mixed native libraries')
        if any(m[k]!=n for k in ('formal_seen','formal_finished','expected_requests')):raise ValueError('Request lifecycle mismatch')
        if next(a for a in w['arm_acks'] if a['rank']==m['rank'])!=m['arm']:raise ValueError('ARM ACK mismatch')
        if next(a for a in w['finalize_acks'] if a['rank']==m['rank'])!=m:raise ValueError('FINALIZE ACK mismatch')
        name=m['csv']
        if Path(name).name!=name:raise ValueError('Unexpected CSV path')
        fpath=path/name
        if digest(fpath)!=m['sha256']:raise ValueError('CSV hash mismatch/truncation')
        rows=[];prev_end=-1;prev_iter=-1
        with fpath.open(newline='') as f:
            reader=csv.DictReader(f)
            if reader.fieldnames!=list(FIELDS):raise ValueError('Incompatible CSV schema; do not use old raw CSV')
            for raw in reader:
                if None in raw or any(x is None for x in raw.values()):raise ValueError('Malformed CSV')
                r={k:v if k in TEXT else int(v) for k,v in raw.items()}
                if any(r[k]<0 for k in FIELDS if k not in TEXT):raise ValueError('Negative values')
                if any(r[k]!=m[k] for k in ('rank','pid','tid','run_id','case_id','session_id')):raise ValueError('Row identity mismatch')
                if r['error'] or r['phase'] not in ('formal_work','formal_cleanup'):raise ValueError('Non-formal/error row')
                t,s=r['total_ns'],r['sync_ns']
                if r['end_ns']-r['start_ns']!=t or not 0<=s<=t:raise ValueError('Invalid T/S')
                if sum(r[k] for k in ('stream_sync_ns','event_sync_ns','other_sync_ns'))!=s:raise ValueError('Sync durations not additive')
                if sum(r[k] for k in ('stream_sync_calls','event_sync_calls','other_sync_calls'))!=r['sync_calls']:raise ValueError('Sync counts not additive')
                if r['formal_iteration']!=len(rows)+1 or r['iteration']<=prev_iter or r['start_ns']<prev_end:raise ValueError('Scope order/overlap error')
                if r['start_ns']<m['arm']['arm_ns'] or r['end_ns']>m['finalize_ns']:raise ValueError('Scope outside boundaries')
                prev_end=r['end_ns'];prev_iter=r['iteration'];rows.append(r)
        if not rows or len(rows)!=m['formal_scopes']:raise ValueError('Incomplete row count')
        if sum(r['sync_calls'] for r in rows)==0:raise ValueError('ZERO intercepted sync calls; H invalid')
        signatures.append([(r['phase'],r['scope'],r['scheduled_tokens'],r['scheduled_requests'],r['finished_requests'],r['graph_launch_calls']) for r in rows])
        # G = sum of wall-clock gaps between adjacent, chronological FORMAL
        # Worker scopes. Never recompute gaps from graph-only subsets: the
        # excluded non-graph scopes would be incorrectly counted as "gap".
        # Both endpoints belong to the same main Worker thread (validated above).
        gap_ns=gap_total_ns(rows)
        for group in GROUPS:
            subset=rows if group=='all_formal' else [r for r in rows if bool(r['graph_launch_calls'])==(group=='graph_formal')]
            result=totals(subset,p)
            # G belongs to all_formal ONLY. It cannot be partitioned reliably
            # into graph_formal and no_graph_formal without a new attribution rule.
            result['G_total_s']=gap_ns/1e9 if group=='all_formal' else None
            result['H_plus_G_total_s']=(result['H_total_s']+gap_ns/1e9) if group=='all_formal' else None
            ranks.append({'case_id':case['case_id'],'run_id':case['run_id'],'rank':m['rank'],'pid':m['pid'],'group':group,'link_percent':p,'warmup_excluded':m['warmup_excluded'],**result})
    # Same TP execution sequence is expected; reject rather than hide incompleteness.
    if any(x!=signatures[0] for x in signatures[1:]):raise ValueError('TP scope/graph sequences differ; inspect before averaging')
    means=[]
    for group in GROUPS:
        rs=[x for x in ranks if x['group']==group]
        means.append({'case_id':case['case_id'],'run_id':case['run_id'],'group':group,'link_percent':p,'ranks':4,'formal_scopes_per_rank':rs[0]['iterations'],'four_rank_mean_T_total_s':statistics.mean(x['T_total_s'] for x in rs),'four_rank_mean_S_total_s':statistics.mean(x['S_total_s'] for x in rs),'four_rank_mean_total_H_s':statistics.mean(x['H_total_s'] for x in rs),'four_rank_mean_G_total_s':statistics.mean(x['G_total_s'] for x in rs) if group=='all_formal' else None,'four_rank_mean_H_plus_G_total_s':statistics.mean(x['H_plus_G_total_s'] for x in rs) if group=='all_formal' else None,'min_rank_total_H_s':min(x['H_total_s'] for x in rs),'max_rank_total_H_s':max(x['H_total_s'] for x in rs)})
    return {'case_id':case['case_id'],'run_id':case['run_id'],'per_rank':ranks,'four_rank':means}

def write_csv(path,rows):
    with Path(path).open('w',newline='') as f:
        if rows:w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)

def analyze(path,out,p=0,print_report=True):
    if not math.isfinite(p) or not 0<=p<=100:raise ValueError('link-percent must be in [0,100]')
    path=Path(path).resolve();out=Path(out).resolve()
    dirs=[path] if (path/'case.json').is_file() else sorted(x.parent for x in path.rglob('case.json'))
    if not dirs:raise ValueError('No new-format case.json; legacy CSV does not identify warmup boundaries')
    data=[case_report(d,p) for d in dirs]
    if len({d['run_id'] for d in data})!=len(data):raise ValueError('Duplicate run ID')
    out.mkdir(parents=True,exist_ok=True);ranks=[r for d in data for r in d['per_rank']];means=[r for d in data for r in d['four_rank']]
    write_csv(out/'per_rank.csv',ranks);write_csv(out/'four_rank_totals.csv',means)
    lines=[f'H = T - S + S * {p:g}/100. Formal scopes only. Unit = SECONDS.',
           'G = sum(start_next - end_current) across adjacent formal scopes on EACH rank.',
           'H+G = H_total + G_total (gap wall time included; sync/idle within G NOT removed).',
           'Primary H remains unchanged; four-rank means are TOTAL seconds, NOT per iteration or instance latency.','']
    for d in data:
        lines.append('CASE: '+d['case_id']+'  run_id='+d['run_id'])
        for r in d['per_rank']:
            if r['group']=='all_formal':
                lines.append(f"  rank{r['rank']} pid={r['pid']} formal={r['iterations']} warmup_excluded={r['warmup_excluded']} "
                             f"T_total={r['T_total_s']:.6f}s S_total={r['S_total_s']:.6f}s H_total={r['H_total_s']:.6f}s "
                             f"G_total={r['G_total_s']:.6f}s H+G={r['H_plus_G_total_s']:.6f}s")
        for r in d['four_rank']:
            lines.append(f"  {r['group']:16s} four_rank_mean_total_H_s={r['four_rank_mean_total_H_s']:.6f}")
        overall=next(r for r in d['four_rank'] if r['group']=='all_formal')
        lines.append(f"FINAL [{d['case_id']}]: four_rank_mean_total_H_s = {overall['four_rank_mean_total_H_s']:.6f} s "
                     f"G_total={overall['four_rank_mean_G_total_s']:.6f}s "
                     f"H+G={overall['four_rank_mean_H_plus_G_total_s']:.6f}s "
                     f"(all_formal, no warmup, gap sync NOT subtracted)")
        lines.append('')
    text='\n'.join(lines)+'\n';(out/'report.txt').write_text(text)
    atomic_json(out/'summary.json',{'link_percent':p,'cases':data})
    if print_report:print(text)
    return data

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('input',type=Path);ap.add_argument('--out',type=Path,required=True);ap.add_argument('--link-percent',type=float,default=0);ap.add_argument('--quiet',action='store_true',help='Write reports without printing results (used by the benchmark script)');a=ap.parse_args()
    try:analyze(a.input,a.out,a.link_percent,print_report=not a.quiet);return 0
    except (OSError,KeyError,ValueError,StopIteration,TypeError) as e:print('ERROR: '+str(e),file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
