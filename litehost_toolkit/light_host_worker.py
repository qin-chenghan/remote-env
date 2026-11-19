from __future__ import annotations
from contextlib import contextmanager
import ctypes,logging,os
from vllm.v1.worker.gpu_worker import Worker
from vllm.v1.utils import compute_iteration_details
from lh_common import VERSION,NATIVE,digest
from lh_runtime import Controller
class Result(ctypes.Structure):_fields_=[(k,ctypes.c_uint64) for k in NATIVE]
class LightHostWorker(Worker):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs)
        if getattr(self,'profiler',None):raise RuntimeError('Disable Torch Profiler for Lite measurement')
        self._lib=ctypes.PyDLL(None)
        self._lib.litehost_build_version.restype=ctypes.c_char_p
        self._lib.litehost_abi_version.restype=ctypes.c_int
        if self._lib.litehost_abi_version()!=1 or self._lib.litehost_build_version().decode()!=VERSION:raise RuntimeError('Wrong/multiple liblitehost.so; build and preload this compatibility package')
        self._lib.litehost_begin.argtypes=[];self._lib.litehost_begin.restype=ctypes.c_int
        self._lib.litehost_end.argtypes=[ctypes.POINTER(Result)];self._lib.litehost_end.restype=ctypes.c_int
        self._lh=Controller(os.environ['LIGHTHOST_SESSION'],int(self.rank),digest(os.environ['LIGHTHOST_LIB']))
        logging.getLogger(__name__).warning('[litehost] rank=%s pid=%s ready version=%s multi-case',self.rank,os.getpid(),VERSION)
    @contextmanager
    def annotate_profile(self,scheduler_output):
        with super().annotate_profile(scheduler_output):
            ctx=self._lh.before(scheduler_output.num_scheduled_tokens,scheduler_output.finished_req_ids)
            measuring=ctx['phase'].startswith('formal');r=Result() if measuring else None
            started=False;label='';error='';native=None
            try:
                if measuring:
                    d=compute_iteration_details(scheduler_output)
                    label=f'execute_context_{d.num_ctx_requests}({d.num_ctx_tokens})_generation_{d.num_generation_requests}({d.num_generation_tokens})'
                    if self._lib.litehost_begin():raise RuntimeError('native begin failed')
                    started=True
                yield
            except BaseException as e:error=f'{type(e).__name__}: {e}';raise
            finally:
                if started:
                    if self._lib.litehost_end(ctypes.byref(r)):error=error or 'native end failed'
                    else:native={k:int(getattr(r,k)) for k in NATIVE}
                self._lh.after(ctx,label,native,error)
                if error=='native end failed':raise RuntimeError(error)
    def shutdown(self):
        try:
            if hasattr(self,'_lh'):self._lh.close()
        finally:super().shutdown()
