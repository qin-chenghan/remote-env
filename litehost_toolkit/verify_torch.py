#!/usr/bin/env python3
"""Natural PyTorch sync/replay smoke test, no model/vLLM/Torch Profiler.
Select one RESERVED GPU. Test synchronizations are not added to benchmarking.
"""
import argparse,ctypes,json,os,subprocess,sys,traceback
from pathlib import Path
from lh_common import VERSION,NATIVE,atomic_json
ROOT=Path(__file__).resolve().parent
class Result(ctypes.Structure):_fields_=[(k,ctypes.c_uint64) for k in NATIVE]
def child(out):
    data={'version':VERSION,'phases':[],'passed':False}
    def save():atomic_json(out/'result.json',data)
    try:
        lib=ctypes.PyDLL(None);lib.litehost_build_version.restype=ctypes.c_char_p
        if lib.litehost_build_version().decode()!=VERSION:raise RuntimeError('Wrong shim version')
        lib.litehost_begin.argtypes=[];lib.litehost_begin.restype=ctypes.c_int
        lib.litehost_end.argtypes=[ctypes.POINTER(Result)];lib.litehost_end.restype=ctypes.c_int
        import torch
        data['torch_version']=str(torch.__version__)
        if not torch.cuda.is_available():raise RuntimeError('No available GPU')
        torch.cuda.set_device(0);x=torch.ones(1024,device='cuda');y=torch.empty_like(x);scalar=torch.ones(1,device='cuda')
        stream=torch.cuda.Stream();event=torch.cuda.Event(enable_timing=False);torch.cuda.synchronize()
        def test(name,action,field,exact=False):
            r=Result()
            if lib.litehost_begin():raise RuntimeError('begin failed')
            try:value=action()
            finally:
                if lib.litehost_end(ctypes.byref(r)):raise RuntimeError('end failed')
            d={k:int(getattr(r,k)) for k in NATIVE};ok=(d[field]==1 if exact else d[field]>0) and 0<=d['sync_ns']<=d['end_ns']-d['start_ns']
            d.update(name=name,passed=ok);data['phases'].append(d);save()
            print(name+': '+('PASS' if ok else 'FAIL')+f" sync={r.sync_calls} stream={r.stream_sync_calls} event={r.event_sync_calls} other={r.other_sync_calls} graph={r.graph_launch_calls}",flush=True)
            return value
        with torch.cuda.stream(stream):torch.add(x,1,out=y)
        test('torch_stream_synchronize',stream.synchronize,'stream_sync_calls')
        with torch.cuda.stream(stream):event.record(stream)
        test('torch_event_synchronize',event.synchronize,'event_sync_calls')
        test('torch_device_synchronize',torch.cuda.synchronize,'other_sync_calls')
        scalar.add_(1)
        if test('tensor_item',scalar.item,'stream_sync_calls')!=2:raise RuntimeError('Tensor result incorrect')
        stream.wait_stream(torch.cuda.current_stream())
        with torch.cuda.stream(stream):
            for _ in range(3):torch.add(x,1,out=y)
        stream.synchronize();g=torch.cuda.CUDAGraph()
        with torch.cuda.graph(g,stream=stream):torch.add(x,1,out=y)
        for i in range(3):test(f'graph_replay_{i}',g.replay,'graph_launch_calls',True)
        torch.cuda.synchronize();data['passed']=len(data['phases'])==7 and all(p['passed'] for p in data['phases'])
        save();print('OVERALL: '+('PASS' if data['passed'] else 'FAIL'),flush=True);return 0 if data['passed'] else 2
    except Exception as e:data['error']=str(e);save();traceback.print_exc();return 2

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--lite-lib',type=Path,default=ROOT/'liblitehost.so');ap.add_argument('--gpu',default='0');ap.add_argument('--out',type=Path,required=True);ap.add_argument('--child',action='store_true');a=ap.parse_args();out=a.out.resolve()
    if a.child:return child(out)
    if not a.lite_lib.is_file() or ',' in a.gpu:ap.error('Build library first; select exactly one GPU')
    out.mkdir(parents=True,exist_ok=False)
    env={k:v for k,v in os.environ.items() if k not in ('LD_PRELOAD','LD_AUDIT','LD_DEBUG','LD_DEBUG_OUTPUT')}
    env.update(LD_PRELOAD=str(a.lite_lib.resolve()),CUDA_VISIBLE_DEVICES=a.gpu,PYTHONUNBUFFERED='1')
    try:
        p=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--child','--out',str(out)],env=env,capture_output=True,text=True,timeout=180)
        (out/'report.txt').write_text(p.stdout);(out/'stderr.log').write_text(p.stderr);print(p.stdout,end='')
        if p.returncode:print(p.stderr,file=sys.stderr)
        return 0 if p.returncode==0 else 2
    except subprocess.TimeoutExpired as e:
        def text(v):return v.decode(errors='replace') if isinstance(v,bytes) else (v or '')
        (out/'report.txt').write_text(text(e.stdout));(out/'stderr.log').write_text(text(e.stderr));print('ERROR: smoke timed out',file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
