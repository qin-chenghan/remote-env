#!/usr/bin/env python3
"""Same installed vLLM client/CLI/parameters; only instrument formal boundaries.
Official warmups remain unchanged. Does not modify installed source files.
"""
from __future__ import annotations
import ast,asyncio,inspect,os,runpy,sys,textwrap,time,hashlib
from dataclasses import replace,is_dataclass
from pathlib import Path
from functools import wraps
from lh_common import atomic_json,read_json,all_ranks

def patch_tree(source):
    tree=ast.parse(textwrap.dedent(source));fn=tree.body[0]
    if len(tree.body)!=1 or not isinstance(fn,ast.AsyncFunctionDef) or fn.name!='benchmark' or fn.decorator_list:raise ValueError('Unsupported benchmark function')
    def assigned(s,n):return isinstance(s,ast.Assign) and len(s.targets)==1 and isinstance(s.targets[0],ast.Name) and s.targets[0].id==n
    starts=[i for i,s in enumerate(fn.body) if assigned(s,'benchmark_start_time')]
    ends=[i for i,s in enumerate(fn.body) if assigned(s,'benchmark_duration')]
    if len(starts)!=1 or len(ends)!=1 or starts[0]>=ends[0]:raise ValueError('Unknown benchmark timer layout')
    a,b=starts[0],ends[0]
    if ast.unparse(fn.body[a].value)!='time.perf_counter()' or ast.unparse(fn.body[b].value)!='time.perf_counter() - benchmark_start_time':raise ValueError('Timer expressions changed')
    warm=[i for i,s in enumerate(fn.body) if isinstance(s,ast.If) and 'num_warmups' in ast.unparse(s.test)]
    if len(warm)!=1 or warm[0]>=a or 'asyncio.gather' not in ast.unparse(fn.body[warm[0]]):raise ValueError('Warmup ordering changed')
    test=[s for s in ast.walk(fn) if assigned(s,'test_input')]
    if len(test)!=1 or not isinstance(test[0].value,ast.Call) or any(k.arg=='request_id' for k in test[0].value.keywords):raise ValueError('Warmup request ID forwarding changed')
    mid='\n'.join(ast.unparse(s) for s in fn.body[a:b])
    if 'request.request_id' not in mid or 'request_id=request_id' not in mid or 'await asyncio.gather(*tasks)' not in mid:raise ValueError('Formal request loop changed')
    body=[]
    for i,s in enumerate(fn.body):
        if i==a:body.extend(ast.parse('await __lh_start()').body)
        body.append(s)
        if i==b:body.extend(ast.parse('await __lh_end(outputs, benchmark_duration)').body)
    fn.body=body;fn.name='__lh_benchmark';return ast.fix_missing_locations(tree)

class Boundaries:
    def __init__(self,session_file,case_dir):
        self.session=read_json(session_file);self.root=Path(case_dir);self.case=read_json(self.root/'case.json')
        if self.case['session_id']!=self.session['session_id']:raise ValueError('Case/session mismatch')
        self.window={'status':'preparing','run_id':self.case['run_id'],'case_id':self.case['case_id'],'session_id':self.case['session_id']}
        self.calls=0;self.ended=False
    def save(self):atomic_json(self.root/'window.json',self.window)
    async def start(self):
        self.window['arm_acks']=await asyncio.to_thread(all_ranks,self.session,'arm',run_id=self.case['run_id'])
        self.window.update(status='armed',main_start_ns=time.monotonic_ns());self.save()
        print('[litehost] 4 ranks ARMED; all ready-check/warmup scopes excluded',flush=True)
    async def end(self,outputs,duration):
        self.window.update(main_end_ns=time.monotonic_ns(),benchmark_duration_s=duration,successful=sum(bool(o.success) for o in outputs),failed=sum(not bool(o.success) for o in outputs))
        if len(outputs)!=self.case['expected_requests'] or not all(o.success for o in outputs):raise RuntimeError('Formal requests incomplete/failed; no valid H')
        self.window['finalize_acks']=await asyncio.to_thread(all_ranks,self.session,'finalize',run_id=self.case['run_id'])
        self.window['status']='finalized';self.ended=True;self.save()
        print('[litehost] 4 ranks FINALIZED; data saved; same server ready for next case',flush=True)

def install(module,b):
    original=module.benchmark;src=inspect.getsource(original);tree=patch_tree(src)
    ns=module.__dict__;ns['__lh_start']=b.start;ns['__lh_end']=b.end
    exec(compile(tree,inspect.getsourcefile(original) or '<bench>','exec'),ns)
    patched=ns['__lh_benchmark'];sig=inspect.signature(original)
    b.window['benchmark_source_sha256']=hashlib.sha256(src.encode()).hexdigest()
    (b.root/'benchmark_hooked.py.txt').write_text(ast.unparse(tree)+'\n')
    @wraps(original)
    async def wrapped(*args,**kwargs):
        b.calls+=1
        if b.calls!=1:raise ValueError('One benchmark call per client process required')
        bind=sig.bind(*args,**kwargs);bind.apply_defaults()
        if bind.arguments.get('profile'):raise ValueError('Torch profiler must be disabled')
        if bind.arguments.get('endpoint_type') not in ('vllm','openai'):raise ValueError('Only original text completions backend supported')
        requests=list(bind.arguments['input_requests'])
        if len(requests)!=b.case['expected_requests']:raise ValueError('Request count mismatch')
        new=[]
        for i,r in enumerate(requests):
            if not is_dataclass(r) or not isinstance(r.prompt,str):raise ValueError('Expected text SampleRequest dataclass')
            if any(getattr(r,k,None) for k in ('multi_modal_data','chat_messages','request_overrides')):raise ValueError('Multimodal/chat/overrides unsupported')
            new.append(replace(r,request_id='lh'+b.case['run_id']+'-'+str(i)))
        bind.arguments['input_requests']=new
        b.window['num_warmups']=bind.arguments.get('num_warmups');b.save()
        return await patched(*bind.args,**bind.kwargs)
    module.benchmark=wrapped

def main():
    b=Boundaries(os.environ['LIGHTHOST_SESSION'],os.environ['LIGHTHOST_CASE_DIR'])
    try:
        import vllm.benchmarks.serve as module
        install(module,b);sys.argv=['vllm','bench','serve',*sys.argv[1:]]
        try:runpy.run_module('vllm.entrypoints.cli.main',run_name='__main__');rc=0
        except SystemExit as e:rc=int(e.code or 0)
        if rc or b.calls!=1 or not b.ended:raise RuntimeError(f'Client incomplete: rc={rc},calls={b.calls},ended={b.ended}')
        b.window['status']='complete';b.save();return 0
    except BaseException as e:
        b.window.update(status='failed',error=f'{type(e).__name__}: {e}');b.save()
        __import__('traceback').print_exc();return 2
if __name__=='__main__':raise SystemExit(main())
