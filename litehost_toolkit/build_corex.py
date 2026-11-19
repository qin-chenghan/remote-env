#!/usr/bin/env python3
"""Derive ix ABI from local SDK declarations AND verify their ELF target names.
No torch/vLLM import, no GPU operations. No untyped ix fallback.
"""
from __future__ import annotations
import argparse,json,os,shlex,subprocess,tempfile
from pathlib import Path
from lh_common import VERSION,atomic_json,digest
ROOT=Path(__file__).resolve().parent
APIS={'ixStreamSynchronize':(1,1),'ixEventSynchronize':(1,2),'ixDeviceSynchronize':(0,3),'ixGraphLaunch':(2,0)}
OPTIONAL={'ixStreamSynchronize_ptsz':(1,1),'ixEventSynchronize_ptsz':(1,2),'ixGraphLaunch_ptsz':(2,0)}
TRAITS='''
#include <atomic>
#include <tuple>
#include <type_traits>
#include "litehost_internal.h"
template<class> struct traits;
template<class R,class...A>struct traits<R(*)(A...)>{using ret=R;using args=std::tuple<A...>;static constexpr int n=sizeof...(A);template<int I>using arg=typename std::tuple_element<I,args>::type;};
template<class R,class...A>struct traits<R(*)(A...)noexcept>:traits<R(*)(A...)>{};
'''
def source(header,mapping):
    out='#include '+json.dumps(str(header))+'\n'+TRAITS
    for n,(expr,arity,kind) in mapping.items():
        ident='wrap_'+n;tr='t_'+n;fn='f_'+n
        args=','.join(f'{tr}::arg<{i}> a{i}' for i in range(arity)) or 'void'
        vals=','.join(f'a{i}' for i in range(arity))
        enter=f'lh_sync_enter({kind});' if kind else 'lh_graph_enter();'
        leave='lh_sync_leave();' if kind else 'lh_graph_leave();'
        out+=f'''using {fn}=decltype(&::{expr});using {tr}=traits<{fn}>;
static_assert({tr}::n=={arity},"Unexpected API arity");
extern "C" {tr}::ret {ident}({args}) __asm__("{n}");
extern "C" {tr}::ret {ident}({args}){{static std::atomic<{fn}>p{{nullptr}};auto f=p.load(std::memory_order_acquire);if(!f){{f=reinterpret_cast<{fn}>(lh_next("{n}"));p.store(f,std::memory_order_release);}}{enter}auto r=f({vals});{leave}return r;}}
static_assert(std::is_convertible<{fn},decltype(&{ident})>::value,"Wrapper type mismatch");
'''
    return out

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--corex-root',type=Path,default=Path('/usr/local/corex'))
    ap.add_argument('--header',type=Path);ap.add_argument('--include',type=Path,action='append',default=[])
    ap.add_argument('--out',type=Path,default=ROOT/'liblitehost.so')
    ap.add_argument('--cc',default=os.environ.get('CC','cc'));ap.add_argument('--cxx',default=os.environ.get('CXX','c++'))
    a=ap.parse_args();a.out=a.out.resolve();a.out.parent.mkdir(parents=True,exist_ok=True)
    logpath=a.out.with_suffix('.build.log');log=logpath.open('w')
    def run(cmd):
        log.write('$ '+shlex.join(map(str,cmd))+'\n');log.flush()
        p=subprocess.run(list(map(str,cmd)),capture_output=True,text=True,timeout=90)
        log.write(p.stdout+p.stderr+f'\nrc={p.returncode}\n');log.flush();return p
    try:
        corex=a.corex_root.resolve()
        rt=next((x for x in [corex/'lib64/libcudart.so.10.2',corex/'lib64/libcudart.so',corex/'lib/libcudart.so'] if x.is_file()),None)
        if rt is None:raise RuntimeError('CoreX Runtime not found')
        p=run(['nm','-D','--defined-only',rt]);exports={l.split()[-1].split('@')[0] for l in p.stdout.splitlines() if l.split()}
        if set(APIS)-exports:raise RuntimeError('Missing required ix exports: '+str(set(APIS)-exports))
        incs=[corex/'include',*a.include,*corex.glob('targets/*/include')]
        flags=sum((['-I',str(x.resolve())] for x in incs if x.is_dir()),[])+['-I',str(ROOT)]
        candidates=[]
        if a.header:candidates=[a.header.resolve()]
        else:
            preferred=['cuda_runtime_api.h','ix_runtime_api.h','ix_runtime.h','cuda_runtime.h','ixrt.h','ixrt_api.h','ix.h']
            for name in preferred:
                for inc in incs:
                    for x in inc.rglob(name) if inc.is_dir() else []:
                        if x.resolve() not in candidates:candidates.append(x.resolve())
        if not candidates:raise RuntimeError('No SDK header found; provide --header and --include')
        cc=shlex.split(a.cc);cxx=shlex.split(a.cxx)
        with tempfile.TemporaryDirectory(prefix='.lhbuild-',dir=a.out.parent) as tmp:
            tmp=Path(tmp);mapping={};header=None
            for h in candidates[:24]:
                candidate={}
                for name,(arity,kind) in APIS.items():
                    for expr in (name,'cuda'+name[2:]):
                        probe=tmp/'probe.cpp';obj=tmp/'probe.o'
                        probe.write_text('#include '+json.dumps(str(h))+'\nextern "C" { __attribute__((used)) decltype(&'+expr+') lh_probe = &'+expr+'; }\n')
                        p=run(cxx+['-std=c++17','-fPIC','-O0',*flags,'-c',probe,'-o',obj])
                        if p.returncode:continue
                        syms=run(['nm','-u',obj]).stdout
                        if name in [l.split()[-1].split('@')[0] for l in syms.splitlines() if l.split()]:
                            candidate[name]=(expr,arity,kind);break
                    if name not in candidate:break
                if len(candidate)==len(APIS):header=h;mapping=candidate;break
            if header is None:raise RuntimeError('SDK declaration/ELF name verification failed; no .so replaced')
            for name,(arity,kind) in OPTIONAL.items():
                if name not in exports:continue
                for expr in (name,'cuda'+name[2:]):
                    probe=tmp/'optional.cpp';obj=tmp/'optional.o'
                    probe.write_text('#include '+json.dumps(str(header))+'\nextern "C" { __attribute__((used)) decltype(&'+expr+') lh_probe = &'+expr+'; }\n')
                    if run(cxx+['-std=c++17','-fPIC','-O0',*flags,'-c',probe,'-o',obj]).returncode:continue
                    syms=run(['nm','-u',obj]).stdout
                    if name in [l.split()[-1].split('@')[0] for l in syms.splitlines() if l.split()]:mapping[name]=(expr,arity,kind);break
            generated=tmp/'ix.cpp';generated.write_text(source(header,mapping))
            commands=[cc+['-O2','-std=c11','-fPIC','-Wall','-Wextra','-c',ROOT/'litehost.c','-o',tmp/'c.o'],
                      cxx+['-O2','-std=c++17','-fPIC','-Wall','-Wextra',*flags,'-c',generated,'-o',tmp/'ix.o'],
                      cxx+['-shared','-Wl,-z,defs',tmp/'c.o',tmp/'ix.o','-ldl','-o',tmp/'liblitehost.so']]
            for cmd in commands:
                if run(cmd).returncode:raise RuntimeError('Compilation failed; inspect '+str(logpath))
            lib=tmp/'liblitehost.so';syms=run(['nm','-D','--defined-only',lib]).stdout
            actual={l.split()[-1].split('@')[0] for l in syms.splitlines() if l.split()}
            if set(mapping)-actual:raise RuntimeError('Output export check failed')
            a.out.with_suffix('.wrappers.cpp').write_text(generated.read_text())
            a.out.with_suffix('.exports.txt').write_text(syms)
            os.chmod(lib,0o755);os.replace(lib,a.out)
            atomic_json(a.out.with_suffix('.build.json'),{'version':VERSION,'library_sha256':digest(a.out),'header':str(header),'header_sha256':digest(header),'runtime':str(rt.resolve()),'mapping':mapping})
        print('BUILD PASS: '+str(a.out)+'\nversion='+VERSION+'\nTyped entries: '+', '.join(mapping));return 0
    except (OSError,RuntimeError,subprocess.TimeoutExpired) as e:
        print(f'BUILD FAILED: {e}\nLog: {logpath}',file=__import__('sys').stderr);return 2
    finally:log.close()
if __name__=='__main__':raise SystemExit(main())
