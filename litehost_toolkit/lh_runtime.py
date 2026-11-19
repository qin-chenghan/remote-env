"""Persistent per-Worker controller. Each PREPARE creates a NEW case state.
The execution thread never waits for the controller. Control thread sleeps in
accept/Condition.wait, never polls and never calls any GPU API.
"""
from __future__ import annotations
import csv,hmac,json,os,re,socket,threading,time,tempfile
from pathlib import Path
from lh_common import VERSION,FIELDS,atomic_json,read_json,recv,digest,name_ok

class Controller:
    def __init__(self,session_file,rank,native_hash):
        self.session=read_json(session_file);self.rank=int(rank);self.pid=os.getpid();self.native_hash=native_hash
        self.root=Path(self.session['run_dir']);self.cv=threading.Condition();self.active=False;self.pending=set();self.tid=None
        self.state='idle';self.case=None;self.used=set();self.iteration=0;self.errors=[]
        self.path=Path(self.session['control_dir'])/f'r{rank}.sock'
        self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.sock.bind(str(self.path));os.chmod(self.path,0o600);self.sock.listen(4)
        self.thread=threading.Thread(target=self._serve,name='lh-control',daemon=True);self.thread.start()
        atomic_json(self.root/'control'/f'rank{rank}.ready.json',self.identity())
    def identity(self):return {'version':VERSION,'session_id':self.session['session_id'],'rank':self.rank,'pid':self.pid,'native_hash':self.native_hash}
    def fail(self,message):
        self.errors.append(message);self.cv.notify_all();raise RuntimeError(message)
    def wait(self,predicate,timeout):
        end=time.monotonic()+timeout
        while not predicate():
            if self.errors:raise RuntimeError(self.errors[0])
            left=end-time.monotonic()
            if left<=0:raise TimeoutError(f'state={self.state},active={self.active},pending={len(self.pending)},seen={len(getattr(self,"seen",{}))},finished={len(getattr(self,"finished",set()))}')
            self.cv.wait(left)
        if self.errors:raise RuntimeError(self.errors[0])
    def index(self,rid):
        if rid not in self.classification:
            m=self.pattern.match(rid);idx=int(m[1]) if m else None
            if idx is not None and not 0<=idx<self.case['expected_requests']:self.fail('formal index outside expected range')
            self.classification[rid]=idx
        return self.classification[rid]
    def before(self,scheduled,finished):
        with self.cv:
            if self.errors:raise RuntimeError(self.errors[0])
            if self.active:self.fail('Concurrent/nested worker scope')
            tid=threading.get_native_id()
            if self.tid is None:self.tid=tid
            if tid!=self.tid:self.fail('Worker execution thread changed')
            self.iteration+=1;scheduled=dict(scheduled);finished=set(finished);ids=set(scheduled)|finished
            if any(int(v)<=0 for v in scheduled.values()):self.fail('nonpositive scheduled token count')
            if self.state=='idle':phase='outside'
            elif self.state=='warmup':
                if any(self.index(r) is not None for r in ids):self.fail('Formal work arrived before ARM')
                phase='warmup'
            elif self.state=='armed':
                if any(self.index(r) is None for r in ids):self.fail('Unmarked/warmup request after ARM')
                phase='formal_work' if scheduled else ('formal_cleanup' if ids or self.pending else 'outside')
                for rid in scheduled:
                    idx=self.index(rid)
                    if self.seen.setdefault(idx,rid)!=rid:self.fail('Multiple internal requests for one index; n>1/retry unsupported')
            elif self.state in ('sealed','complete'):
                if ids or self.pending:self.fail('Work arrived after FINALIZE and before next PREPARE')
                phase='outside'
            else:self.fail('Invalid controller state')
            self.active=True
            return {'iteration':self.iteration,'phase':phase,'scheduled':scheduled,'finished':finished,'tid':tid}
    def after(self,ctx,label,native,error=''):
        with self.cv:
            try:
                self.pending.update(ctx['scheduled']);self.pending.difference_update(ctx['finished'])
                if ctx['phase'].startswith('formal'):
                    for rid in ctx['finished']:
                        i=self.index(rid)
                        if self.seen.get(i)!=rid:self.errors.append('Finish notification for unseen formal request')
                        self.finished.add(i)
                    if native is None:self.errors.append('No native result')
                    else:
                        row=dict(native);row.update(session_id=self.session['session_id'],case_id=self.case['case_id'],run_id=self.case['run_id'],rank=self.rank,pid=self.pid,tid=ctx['tid'],iteration=ctx['iteration'],formal_iteration=len(self.rows)+1,phase=ctx['phase'],scope=label,scheduled_requests=len(ctx['scheduled']),scheduled_tokens=sum(ctx['scheduled'].values()),finished_requests=len(ctx['finished']),total_ns=native['end_ns']-native['start_ns'],error=error)
                        self.rows.append(row)
                        if len(self.rows)>self.session['max_scopes']:self.errors.append('Max formal scopes exceeded')
                elif ctx['phase']=='warmup':self.warmup+=1
                if error:self.errors.append(error)
            finally:self.active=False;self.cv.notify_all()
            if self.errors and not error:raise RuntimeError(self.errors[0])
    def command(self,command,timeout,case_id=None,run_id=None):
        with self.cv:
            if command=='status':return {**self.identity(),'state':self.state,'pending':len(self.pending),'case':self.case}
            if command=='prepare':
                if self.state not in ('idle','complete'):raise RuntimeError('Previous case is not complete; refusing reset')
                self.wait(lambda:not self.active and not self.pending,timeout)
                case=read_json(self.root/'litehost'/name_ok(case_id)/'case.json')
                if case['session_id']!=self.session['session_id']:raise RuntimeError('Wrong session')
                if not re.fullmatch('[0-9a-f]{32}',case['run_id']):raise ValueError('Invalid run ID')
                if case['run_id'] in self.used:raise RuntimeError('Reused case run ID')
                if case['expected_requests']<=0:raise ValueError('Request count must be positive')
                self.case=case;self.used.add(case['run_id']);self.rows=[];self.seen={};self.finished=set();self.classification={};self.warmup=0
                self.pattern=re.compile(r'^(?:cmpl-)?lh'+case['run_id']+r'-(\d+)(?:-|$)')
                self.state='warmup';return {**self.identity(),'run_id':case['run_id'],'state':self.state}
            if self.case is None or run_id!=self.case['run_id']:raise RuntimeError('Wrong active case run ID')
            if command=='arm':
                if self.state!='warmup':raise RuntimeError('ARM requires warmup state')
                self.wait(lambda:not self.active and not self.pending,timeout)
                self.state='armed';self.arm={**self.identity(),'run_id':run_id,'arm_ns':time.monotonic_ns(),'warmup_excluded':self.warmup,'pending':0}
                return dict(self.arm)
            if command!='finalize':raise ValueError('Unknown control command')
            if self.state=='complete':return dict(self.final)
            if self.state!='armed':raise RuntimeError('FINALIZE requires armed state')
            n=self.case['expected_requests'];self.wait(lambda:not self.active and not self.pending and len(self.seen)==n and len(self.finished)==n,timeout)
            if not self.rows:raise RuntimeError('No formal rows')
            self.state='sealed';rows=list(self.rows);case=dict(self.case)
        out=self.root/'litehost'/case['case_id'];csv_path=out/f'rank{self.rank}_pid{self.pid}.csv'
        fd,tmp=tempfile.mkstemp(prefix='.rows-',dir=out)
        try:
            with os.fdopen(fd,'w',newline='') as f:
                w=csv.DictWriter(f,fieldnames=FIELDS);w.writeheader();w.writerows(rows);f.flush();os.fsync(f.fileno())
            os.replace(tmp,csv_path)
        finally:
            if os.path.exists(tmp):os.unlink(tmp)
        final={**self.identity(),'tid':self.tid,'run_id':run_id,'case_id':case['case_id'],'status':'complete','formal_scopes':len(rows),'formal_seen':len(self.seen),'formal_finished':len(self.finished),'expected_requests':n,'warmup_excluded':self.warmup,'pending':0,'arm':self.arm,'finalize_ns':time.monotonic_ns(),'csv':csv_path.name,'sha256':digest(csv_path),'errors':list(self.errors)}
        with self.cv:
            if self.errors:raise RuntimeError(self.errors[0])
            atomic_json(csv_path.with_suffix('.meta.json'),final);self.final=final;self.rows=[];self.state='complete'
        return dict(final)
    def _serve(self):
        while True:
            try:c,_=self.sock.accept()
            except OSError:return
            with c:
                c.settimeout(650)
                try:
                    req=recv(c)
                    if not hmac.compare_digest(str(req.get('token','')),self.session['token']):raise PermissionError('Invalid token')
                    timeout=float(req.get('timeout',120))
                    if not 0<timeout<=600:raise ValueError('Invalid timeout')
                    result=self.command(req['command'],timeout,req.get('case_id'),req.get('run_id'));reply={'ok':True,'result':result}
                except Exception as e:reply={'ok':False,'error':f'{type(e).__name__}: {e}'}
                try:c.sendall((json.dumps(reply)+'\n').encode())
                except OSError:pass
    def close(self):
        try:self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:pass
        self.sock.close()
