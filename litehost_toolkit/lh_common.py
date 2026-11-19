"""Shared, stdlib-only protocol for one server and multiple isolated cases."""
from __future__ import annotations
import hashlib,json,os,re,socket,tempfile
from pathlib import Path
VERSION='0.4.0-compat'
NATIVE=('start_ns','end_ns','thread_cpu_ns','sync_ns','stream_sync_ns','event_sync_ns','other_sync_ns','sync_calls','stream_sync_calls','event_sync_calls','other_sync_calls','graph_launch_calls')
FIELDS=('session_id','case_id','run_id','rank','pid','tid','iteration','formal_iteration','phase','scope','scheduled_requests','scheduled_tokens','finished_requests',*NATIVE,'total_ns','error')

def read_json(path):
    with Path(path).open(encoding='utf-8') as f: return json.load(f)

def atomic_json(path,data):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.'+path.name,dir=path.parent)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            json.dump(data,f,indent=2,ensure_ascii=False,allow_nan=False);f.write('\n');f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for x in iter(lambda:f.read(1048576),b''):h.update(x)
    return h.hexdigest()

def name_ok(value):
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,100}',value) or value in ('.','..'):raise ValueError('Invalid case/test name')
    return value

def recv(sock):
    data=bytearray()
    while b'\n' not in data:
        b=sock.recv(65536)
        if not b:raise RuntimeError('Control connection ended')
        data.extend(b)
        if len(data)>2**22:raise ValueError('Control message too large')
    return json.loads(data.split(b'\n')[0])

def rpc(session,rank,command,**args):
    timeout=float(session.get('timeout',120))
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
        s.settimeout(timeout+10);s.connect(str(Path(session['control_dir'])/f'r{rank}.sock'))
        req={'token':session['token'],'command':command,'timeout':timeout,**args}
        s.sendall((json.dumps(req)+'\n').encode());out=recv(s)
    if not out.get('ok'):raise RuntimeError(f'rank{rank} {command}: {out.get("error")}')
    return out['result']

def all_ranks(session,command,**args):
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=4) as pool:
        return list(pool.map(lambda r:rpc(session,r,command,**args),range(4)))
