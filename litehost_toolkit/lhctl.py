#!/usr/bin/env python3
"""Setup and per-case hooks for the original shell lifecycle; never starts vLLM."""
from __future__ import annotations
import argparse,ast,importlib.util,json,os,shutil,sys,tempfile,uuid
from pathlib import Path
from lh_common import VERSION,atomic_json,read_json,digest,all_ranks,name_ok
ROOT=Path(__file__).resolve().parent

def preflight(source_root=None):
    if source_root is None:
        spec=importlib.util.find_spec('vllm')
        if spec is None or not spec.submodule_search_locations:raise ValueError('vLLM not installed for selected Python')
        source_root=Path(next(iter(spec.submodule_search_locations)))
    source_root=Path(source_root)
    source=(source_root/'benchmarks/serve.py').read_text();tree=ast.parse(source)
    fn=next(n for n in tree.body if isinstance(n,ast.AsyncFunctionDef) and n.name=='benchmark')
    from bench_driver import patch_tree
    patch_tree(ast.get_source_segment(source,fn))
    endpoint=ast.parse((source_root/'benchmarks/lib/endpoint_request_func.py').read_text())
    update=next(n for n in endpoint.body if isinstance(n,ast.FunctionDef) and n.name=='_update_headers_common')
    if "headers['x-request-id'] = request_func_input.request_id" not in ast.unparse(update):raise ValueError('Request ID header forwarding changed')
    worker=ast.parse((source_root/'v1/worker/gpu_worker.py').read_text())
    klass=next(n for n in worker.body if isinstance(n,ast.ClassDef) and n.name=='Worker')
    execute=next(n for n in klass.body if isinstance(n,ast.FunctionDef) and n.name=='execute_model')
    scopes=[n for n in ast.walk(execute) if isinstance(n,ast.With) and any(ast.unparse(i.context_expr)=='self.annotate_profile(scheduler_output)' for i in n.items)]
    if len(scopes)!=1 or 'self.model_runner.execute_model' not in ast.unparse(scopes[0]):raise ValueError('Worker scope boundary changed')
    return {'status':'pass','source_root':str(source_root),'files':{n:digest(source_root/n) for n in ['benchmarks/serve.py','benchmarks/lib/endpoint_request_func.py','v1/worker/gpu_worker.py']}}

def init_session(run_dir,timeout,max_scopes):
    run_dir=Path(run_dir).resolve();run_dir.mkdir(parents=True,exist_ok=True)
    if (run_dir/'session.json').exists():raise ValueError('Existing session; use a NEW TEST_ID')
    build=read_json(ROOT/'liblitehost.build.json')
    if build['version']!=VERSION or build['library_sha256']!=digest(ROOT/'liblitehost.so'):raise ValueError('Wrong native build; run make in THIS package')
    check=preflight();control=tempfile.mkdtemp(prefix='lhc-');os.chmod(control,0o700)
    session={'version':VERSION,'session_id':uuid.uuid4().hex,'token':uuid.uuid4().hex+uuid.uuid4().hex,'run_dir':str(run_dir),'control_dir':control,'timeout':timeout,'max_scopes':max_scopes,'native_hash':build['library_sha256'],'source_check':check}
    atomic_json(run_dir/'session.json',session);os.chmod(run_dir/'session.json',0o600);return session

def prepare(session_path,case_id,n,input_len,output_len):
    session=read_json(session_path);out=Path(session['run_dir'])/'litehost'/name_ok(case_id)
    out.mkdir(parents=True,exist_ok=False)
    status=all_ranks(session,'status')
    if {s['rank'] for s in status}!={0,1,2,3} or len({s['pid'] for s in status})!=4:raise ValueError('Four distinct worker processes required')
    if any(s['session_id']!=session['session_id'] or s['native_hash']!=session['native_hash'] or s['state'] not in ('idle','complete') for s in status):raise ValueError('Invalid session/native hash/previous case state')
    case={'version':VERSION,'session_id':session['session_id'],'run_id':uuid.uuid4().hex,'case_id':case_id,'status':'preparing','expected_requests':n,'input_len':input_len,'output_len':output_len,'native_hash':session['native_hash']}
    atomic_json(out/'case.json',case)
    try:case['prepare_acks']=all_ranks(session,'prepare',case_id=case_id);case['status']='prepared';atomic_json(out/'case.json',case)
    except Exception as e:case.update(status='failed',error=str(e));atomic_json(out/'case.json',case);raise
    print('PREPARED: '+str(out));return out

def finish(path,p):
    path=Path(path);case=read_json(path/'case.json');window=read_json(path/'window.json')
    if window['status']!='complete' or window['run_id']!=case['run_id']:raise ValueError('Client boundaries incomplete')
    case['status']='complete';atomic_json(path/'case.json',case)
    from analyze_litehost import analyze
    try:return analyze(path,path/'host_report',p,print_report=False)
    except Exception as e:case.update(status='failed',error=str(e));atomic_json(path/'case.json',case);raise

def summary(run_dir):
    from analyze_litehost import write_csv
    run_dir=Path(run_dir)
    aliases={'successful_requests':['successful_requests','completed'],'benchmark_duration_s':['benchmark_duration_s','duration'],'request_throughput_req_s':['request_throughput','request_throughput_req_s'],'output_token_throughput_tok_s':['output_throughput','output_token_throughput'],'total_token_throughput_tok_s':['total_token_throughput']}
    for metric in ('ttft','tpot','itl'):
        for stat in ('mean','median','p99'):aliases[f'{stat}_{metric}_ms']=[f'{stat}_{metric}_ms']
    rows=[]
    for path in sorted(run_dir.glob('bs*_in*_out*.json')):
        data=read_json(path);row={'test_id':run_dir.name,'case':path.stem}
        for k,names in aliases.items():
            row[k]=next((d[n] for d in (data,data.get('metrics',{})) if isinstance(d,dict) for n in names if n in d),'')
        rows.append(row)
    write_csv(run_dir/'summary.csv',rows);print('Wrote '+str(run_dir/'summary.csv'))

def main():
    ap=argparse.ArgumentParser(description=__doc__);sub=ap.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('check');p.add_argument('--source-root',type=Path)
    p=sub.add_parser('init');p.add_argument('--run-dir',required=True,type=Path);p.add_argument('--timeout',type=float,default=120);p.add_argument('--max-scopes',type=int,default=200000)
    p=sub.add_parser('prepare');p.add_argument('--session',required=True);p.add_argument('--case-id',required=True);p.add_argument('--num-prompts',type=int,required=True);p.add_argument('--input-len',type=int,required=True);p.add_argument('--output-len',type=int,required=True)
    p=sub.add_parser('finish');p.add_argument('case_dir');p.add_argument('--link-percent',type=float,default=0)
    p=sub.add_parser('summary');p.add_argument('run_dir')
    p=sub.add_parser('cleanup-control');p.add_argument('--session',required=True)
    a=ap.parse_args()
    try:
        if a.cmd=='check':print(json.dumps(preflight(a.source_root),indent=2))
        elif a.cmd=='init':
            if not 0<a.timeout<=600 or a.max_scopes<=0:raise ValueError('Invalid timeout/max-scopes')
            print('SESSION: '+init_session(a.run_dir,a.timeout,a.max_scopes)['session_id'])
        elif a.cmd=='prepare':
            if min(a.num_prompts,a.input_len,a.output_len)<=0:raise ValueError('Counts must be positive')
            prepare(a.session,a.case_id,a.num_prompts,a.input_len,a.output_len)
        elif a.cmd=='finish':finish(a.case_dir,a.link_percent)
        elif a.cmd=='summary':summary(a.run_dir)
        elif a.cmd=='cleanup-control':
            s=read_json(a.session);d=Path(s['control_dir'])
            if d.parent!=Path(tempfile.gettempdir()) or not d.name.startswith('lhc-'):raise ValueError('Unexpected control path')
            shutil.rmtree(d,ignore_errors=True)
        return 0
    except Exception as e:print(f'ERROR: {type(e).__name__}: {e}',file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
