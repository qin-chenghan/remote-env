import contextlib
import ctypes
import functools
import os

import torch


def _c_noop_funcs():
    """C no-ops for the fake device's sync APIs.

    Python shims show up as python_function frames in the profile; the base
    trace has none because these are CUDA runtime calls the profiler does not
    record. sched_yield is used purely as a callable address that accepts and
    ignores its arguments. functools.partial keeps the objects hashable:
    dynamo indexes torch attributes such as torch.accelerator.synchronize by
    identity, and raw ctypes function pointers are unhashable.
    """
    lib = ctypes.CDLL(None)
    return (
        functools.partial(ctypes.CFUNCTYPE(None)(("sched_yield", lib))),
        functools.partial(
            ctypes.CFUNCTYPE(None, ctypes.py_object)(("sched_yield", lib))
        ),
    )


_C_NOOP0, _C_NOOP1 = _c_noop_funcs()


class _FakeStream:
    wait_stream = staticmethod(_C_NOOP1)
    wait_event = staticmethod(_C_NOOP1)
    synchronize = staticmethod(_C_NOOP0)

    def __init__(self, *a, **k):
        pass

    def record_event(self, *a, **k):
        return _FakeEvent()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class _FakeEvent:
    record = staticmethod(_C_NOOP0)
    synchronize = staticmethod(_C_NOOP0)
    wait = staticmethod(_C_NOOP1)

    def __init__(self, *a, **k):
        pass

    def elapsed_time(self, *a, **k):
        return 0.0


class _SingleRankGroup:
    world_size = 1
    rank = 0
    ranks = [0]
    local_rank = 0
    rank_in_group = 0
    cpu_group = None
    device_group = None
    device = torch.device("cpu")

    @property
    def first_rank(self):
        return 0

    @property
    def last_rank(self):
        return 0

    @property
    def is_first_rank(self):
        return True

    @property
    def is_last_rank(self):
        return True

    def graph_capture(self, ctx=None):
        return contextlib.nullcontext(ctx)

    def all_reduce(self, input_, *a, **k):
        return input_

    def all_gather(self, input_, *a, **k):
        return input_

    def reduce_scatter(self, input_, *a, **k):
        return input_

    def broadcast_tensor_dict(self, tensor_dict=None, *a, **k):
        return tensor_dict or {}

    def send_tensor_dict(self, *a, **k):
        return None

    def recv_tensor_dict(self, *a, **k):
        return {}

    def prepare_communication_buffer_for_model(self, model):
        return None

    def destroy(self):
        return None


def _init_single_rank_parallel_state():
    import vllm.distributed.parallel_state as ps

    g = _SingleRankGroup()
    for name in ("_WORLD", "_TP", "_DCP", "_PP", "_DP", "_EP", "_EPLB", "_PCP"):
        setattr(ps, name, g)
    ps._NODE_COUNT = 1


def _patch_accelerator():
    acc = getattr(torch, "accelerator", None)
    if acc is None:
        return
    acc.synchronize = _C_NOOP0
    acc.empty_cache = lambda *a, **k: None
    acc.current_device_index = lambda *a, **k: 0
    acc.set_device_index = lambda *a, **k: None


def _patch_compute_units():
    import vllm.utils.platform_utils as pu

    pu.num_compute_units = lambda device_id=0: 64


_GRAPH_LAUNCH = None


def _make_sync():
    """Return the sync stub and wire the graph-launch stub the same way.

    Lite measures H per scope and splits scopes on graph launches, so replay
    has to issue one through the preloaded tool, like a real launch.
    """
    global _GRAPH_LAUNCH
    _GRAPH_LAUNCH = None
    lib = os.environ.get("LIGHTHOST_LIB")
    ix = os.environ.get("MOCK_IX_LIB", "/home/qch/mock_vllm/mock_ix.so")
    if lib and os.environ.get("LIGHTHOST_SESSION") and os.path.exists(lib):
        try:
            ctypes.CDLL(ix, mode=ctypes.RTLD_GLOBAL)
            handle = ctypes.CDLL(lib)
            fn = handle.ixDeviceSynchronize
            fn.restype = ctypes.c_int
            fn.argtypes = []
            gl = getattr(handle, "cudaGraphLaunch", None) or getattr(
                handle, "ixGraphLaunch", None
            )
            if gl is not None:
                # Keep the call in C: a Python wrapper would show as a
                # profile frame that base does not have. partial keeps it
                # hashable for dynamo's attribute table.
                _GRAPH_LAUNCH = functools.partial(ctypes.CFUNCTYPE(None)(gl))
            return functools.partial(fn)
        except Exception as exc:
            print(f"[mock_gpu] litehost sync stub failed: {exc}", flush=True)
    return _C_NOOP0


_MOCK_STREAM = _FakeStream()


def _stream_tls():
    """vLLM caches the current stream in a thread-local to skip the constructor."""
    try:
        from vllm.utils.torch_utils import _current_stream_tls

        return _current_stream_tls
    except Exception:
        return None


def _set_stream(stream):
    tls = _stream_tls()
    if tls is not None:
        tls.value = stream


def _current_stream(*a, **k):
    tls = _stream_tls()
    if tls is not None:
        return getattr(tls, "value", _MOCK_STREAM)
    return _MOCK_STREAM


class _StreamCtx:
    def __init__(self, stream):
        self.stream = stream
        self.prev = None

    def __enter__(self):
        self.prev = _current_stream()
        _set_stream(self.stream)
        return self.stream

    def __exit__(self, *a):
        _set_stream(self.prev)
        return False


def _patch_weak_ref():
    """Weak refs exist to drop capture-time allocations; CPU tensors have no
    ixfops equivalent, and memory is fake here, so identity is enough."""
    import vllm.utils.torch_utils as tu

    tu.weak_ref_tensor = lambda t: t
    tu.weak_ref_tensors = lambda ts: ts
    try:
        import vllm.compilation.cuda_graph as cg

        cg.weak_ref_tensors = lambda ts: ts
    except Exception:
        pass


def _patch_cuda_stubs():
    from mock_gpu import fake_graph

    fake_graph.install(torch.cuda)
    torch.cuda.mem_get_info = lambda *a, **k: (8 * 1024 ** 3, 8 * 1024 ** 3)
    torch.cuda.is_current_stream_capturing = lambda *a, **k: False
    torch.cuda.Stream = _FakeStream
    torch.cuda.Event = _FakeEvent
    torch.Event = _FakeEvent
    torch.cuda.stream = lambda stream=None, *a, **k: _StreamCtx(stream or _MOCK_STREAM)
    torch.cuda.synchronize = _make_sync()
    torch.cuda.current_stream = _current_stream
    torch.cuda.default_stream = lambda *a, **k: _MOCK_STREAM
    torch.cuda.set_stream = _set_stream
    torch.cuda.set_device = lambda *a, **k: None
    torch.cuda.get_device_index = lambda *a, **k: 0
    _set_stream(_MOCK_STREAM)


def _disable_pin_memory():
    import vllm.utils.platform_utils as pu

    pu.is_pin_memory_available = lambda: False
    import vllm.v1.worker.gpu_model_runner as gmr

    gmr.is_pin_memory_available = lambda: False


def _patch_triton_launch():
    """Keep the triton launcher frames, skip the compile/launch.

    vLLM disables triton when no driver is present, which turns the decorated
    kernels into plain functions. Re-wrapping the one hot kernel in a real
    JITFunction and stubbing JITFunction.run keeps the base frames
    (jit.py __getitem__, <lambda>, run) with no device work; the stub is
    compiled at the original file/line so the frame names match.
    """
    import triton.runtime.jit as jitmod

    orig = jitmod.JITFunction.run
    if not getattr(orig, "_mock_run_stub", False):
        code = orig.__code__
        src = "\n" * (code.co_firstlineno - 1) + (
            "def run(self, *args, grid, warmup, **kwargs):\n    return None\n"
        )
        ns = {}
        exec(compile(src, code.co_filename, "exec"), ns)
        ns["run"]._mock_run_stub = True
        jitmod.JITFunction.run = ns["run"]

    import vllm.v1.worker.block_table as btmod

    k = btmod._compute_slot_mapping_kernel
    if not isinstance(k, jitmod.JITFunction) and not getattr(
        k, "_mock_jitfunc", False
    ):
        wrapped = jitmod.JITFunction(k)
        wrapped._mock_jitfunc = True
        btmod._compute_slot_mapping_kernel = wrapped


def init_single_rank_parallel_state():
    _init_single_rank_parallel_state()




def _patch_ixf_linear_launch():
    """Skip only the kernel launch under IXF.linear.

    lm_head is excluded from quantization (compressed-tensors ignore list), so
    compute_logits goes through default_unquantized_gemm -> IXF.linear. That
    host prep (contiguity, gemv_conditions, input.new_empty) stays real; only
    the pybind call that enqueues the GEMM is replaced by returning the
    already-allocated output.
    """
    import ixformer._C as ixC

    ixC.infer.linear_ex = lambda input, weight, bias, output: output
    ixC.infer.linear = lambda input, weight, act_type, bias, output, persistent: output


_PREFILL_KERNELS = (
    "w8a8_gemm",
    "w8a8_gemv",
    "scaled_int8_quant",
    "residual_rms_norm",
    "rms_norm",
    "rms_norm_qk",
    "vllm_rotary_embedding",
    "vllm_reshape_and_cache",
    "silu_and_mul",
    "ixinfer_flash_attn_unpad",
    "ixinfer_flash_attn_unpad_with_block_tables",
    "vllm_paged_attention",
    "vllm_paged_attention_mtp",
)
_COMM_OPS = (
    "all_reduce",
    "all_gather",
    "gather",
    "broadcast",
    "reduce_scatter",
    "send",
    "recv",
    "destroy",
)


def _noop(*a, **k):
    return None


def _patch_prefill_kernels():
    """Drop only the device call under each ixformer kernel wrapper.

    Each wrapper in ixformer/inference/functions allocates its output and then
    calls the pybind op in place; the torch.ops route has the same shape when
    IXFORMER_USE_TORCH_OPS is on. Replacing the op keeps the wrapper frame and
    the allocation, and removes only the launch. MOCK_PREFILL=0 turns it off.
    """
    if os.environ.get("MOCK_PREFILL", "1") == "0":
        return
    import ixformer._C as ixC

    for name in _PREFILL_KERNELS:
        if hasattr(ixC.infer, name):
            setattr(ixC.infer, name, _noop)
    try:
        ns = torch.ops._ixformer_C
        for name in _PREFILL_KERNELS:
            if hasattr(ns, name):
                setattr(ns, name, _noop)
    except Exception:
        pass


def _patch_comm_ops():
    """Drop the pybind call under ixfd, keep _check_group and the wrappers.

    The communicator handle is a sentinel that _check_group passes through
    untouched, so every host frame up to the pybind leaf stays the same.
    """
    try:
        from ixformer._C._distributed import comm as ixc_comm

        for name in _COMM_OPS:
            if hasattr(ixc_comm, name):
                setattr(ixc_comm, name, _noop)
    except Exception:
        pass


_POST_LOAD = False


@contextlib.contextmanager
def weight_post_load():
    """Mark process_weights_after_loading; big transposed copies are device work."""
    global _POST_LOAD
    prev = _POST_LOAD
    _POST_LOAD = True
    try:
        yield
    finally:
        _POST_LOAD = prev


def _patch_contiguous():
    """Keep the contiguous allocation, drop the element move, at load time only.

    Quant post-load does `weight.data.t().contiguous()` per layer: on device a
    copy kernel, on CPU a GB-scale host copy whose values the mock never reads.
    Returning a correctly-shaped contiguous empty buffer keeps the layout and
    the allocation while skipping the copy. Already-contiguous tensors fall
    through to the real method (it just returns self).
    """
    orig = torch.Tensor.contiguous
    if getattr(orig, "_mock_contig_stub", False):
        return

    def contiguous(self, *args, **kwargs):
        if _POST_LOAD and self.numel() >= 1_000_000 and not self.is_contiguous():
            return torch.empty_like(self, memory_format=torch.contiguous_format)
        return orig(self, *args, **kwargs)

    contiguous._mock_contig_stub = True
    contiguous._mock_orig = orig
    torch.Tensor.contiguous = contiguous


_SAMPLE_PHASE = False


def _patch_tensor_copy():
    """Keep the H2D/D2H host preparation, drop the transfer.

    vLLM issues every device transfer as copy_(..., non_blocking=True) inside
    a CpuGpuBuffer helper. Skipping exactly those leaves the vLLM frame and
    the slice/allocation work intact while moving no bytes.
    """
    orig = torch.Tensor.copy_
    if getattr(orig, "_mock_copy_stub", False):
        return

    def copy_(self, src, *args, **kwargs):
        nb = kwargs.get("non_blocking")
        if nb is None and len(args) >= 2:
            nb = args[1]
        if nb:
            # A zero-length copy keeps the aten::copy_ frame while moving
            # no bytes; both sides come from the same CpuGpuBuffer shape.
            if self.shape == getattr(src, "shape", None) and self.dim():
                orig(self.narrow(0, 0, 0), src.narrow(0, 0, 0), *args, **kwargs)
            return self
        return orig(self, src, *args, **kwargs)

    copy_._mock_copy_stub = True
    copy_._mock_orig = orig
    torch.Tensor.copy_ = copy_


@contextlib.contextmanager
def weight_load_phase():
    """Scope the transfer stubs to model loading.

    Both stubs skip device work that only happens while the checkpoint is
    loaded. Left installed, they would add a python frame to every profiled
    copy/contiguous call that base does not record, so they are removed again
    before serving starts; the per-step copies are small enough to run for
    real on the host.
    """
    _patch_contiguous()
    _patch_tensor_copy()
    try:
        yield
    finally:
        for name in ("contiguous", "copy_"):
            cur = getattr(torch.Tensor, name)
            orig = getattr(cur, "_mock_orig", None)
            if orig is not None:
                setattr(torch.Tensor, name, orig)


_CAST_CACHE = {}


@contextlib.contextmanager
def sample_phase():
    """Mark the sampler scope; big dtype casts there are device work."""
    global _SAMPLE_PHASE
    prev = _SAMPLE_PHASE
    _SAMPLE_PHASE = True
    try:
        yield
    finally:
        _SAMPLE_PHASE = prev


def _patch_sample_cast():
    """Keep the dtype/alloc of the sampler's fp32 logits, skip the conversion.

    MOCK_SAMPLE_CAST=0 disables the stub (control runs).

    Sampler.forward does logits.to(torch.float32) on the full vocab; on GPU
    that is a kernel plus an allocation, and on CPU it is a real conversion of
    tens of MB per step. Inside the sample scope we return a fresh empty fp32
    tensor of the same shape instead: same dtype and allocation cost, without
    doing the device-side elementwise work on the host.
    """
    if os.environ.get("MOCK_SAMPLE_CAST", "1") == "0":
        return
    orig = torch.Tensor.to
    if getattr(orig, "_mock_cast_stub", False):
        return

    def to(self, *args, **kwargs):
        if _SAMPLE_PHASE and self.numel() >= 100_000:
            dtype = kwargs.get("dtype")
            if dtype is None:
                for a in args:
                    if isinstance(a, torch.dtype):
                        dtype = a
                        break
            if dtype is not None and dtype.is_floating_point and self.dtype != dtype:
                key = (tuple(self.shape), dtype)
                buf = _CAST_CACHE.get(key)
                if buf is None:
                    if len(_CAST_CACHE) >= 4:
                        _CAST_CACHE.clear()
                    buf = torch.zeros(self.shape, dtype=dtype, device=self.device)
                    _CAST_CACHE[key] = buf
                # Emit the aten cast frame; no elements are converted.
                orig(self.narrow(0, 0, 0), dtype=dtype)
                return buf
        return orig(self, *args, **kwargs)

    to._mock_cast_stub = True
    torch.Tensor.to = to


def _tune_threads():
    """Match the intra-op pool real workers get.

    vLLM's multiproc setup pins GPU workers to a single torch thread
    (OMP_NUM_THREADS=1); leaving the mock at the default 256 or an
    affinity-sized pool makes the CPU fallbacks (aten::index, index_select)
    many times slower under 4-way TP contention.
    """
    torch.set_num_threads(int(os.environ.get("MOCK_THREADS", "1")))


def _pin_worker(rank):
    """Pin one TP worker to the core chosen for it.

    MOCK_TP_CPUS is a comma list indexed by rank, e.g. "8,10,11,12". The
    point is to leave a core free for an external sampler: exclude that core
    from the harness CPU range and pin the sampler to it.

    A worker has many threads (gloo, torch, runtime pools); affinity is set
    on all of them here and inherited by threads created later, which only
    works because this runs before the model is built.
    """
    spec = os.environ.get("MOCK_TP_CPUS", "").strip()
    if not spec:
        return
    try:
        cpus = [int(x) for x in spec.split(",") if x.strip()]
        cpu = cpus[rank]
    except (IndexError, ValueError):
        print(f"[mock_gpu] MOCK_TP_CPUS invalid for rank {rank}: {spec}", flush=True)
        return
    try:
        os.sched_setaffinity(0, {cpu})
        for tid in os.listdir("/proc/self/task"):
            try:
                os.sched_setaffinity(int(tid), {cpu})
            except OSError:
                pass
        print(f"[mock_gpu] rank {rank} pinned to cpu {cpu}", flush=True)
    except OSError as exc:
        print(f"[mock_gpu] rank {rank} pin to cpu {cpu} failed: {exc}", flush=True)


def patch_worker(gw):
    _tune_threads()
    from mock_gpu.dispatch import install_method_stubs

    install_method_stubs()
    _patch_ixf_linear_launch()
    _patch_prefill_kernels()
    _patch_comm_ops()
    _patch_sample_cast()
    _patch_cuda_stubs()
    _patch_weak_ref()
    _patch_accelerator()
    _patch_compute_units()
    _disable_pin_memory()
    _patch_triton_launch()
    Worker = gw.Worker

    def init_device(self):
        self.device = torch.device("cpu")
        _pin_worker(self.rank)
        self.parallel_config.disable_custom_all_reduce = True
        try:
            gw.set_custom_all_reduce(False)
        except Exception:
            pass
        if self.parallel_config.world_size == 1:
            _init_single_rank_parallel_state()
        else:
            gw.init_distributed_environment(
                self.parallel_config.world_size,
                self.rank,
                self.distributed_init_method,
                self.local_rank,
                "gloo",
            )
            gw.ensure_model_parallel_initialized(
                self.parallel_config.tensor_parallel_size,
                self.parallel_config.pipeline_parallel_size,
                1,
                self.parallel_config.decode_context_parallel_size,
                "gloo",
            )
        gw.set_random_seed(self.model_config.seed)
        num_ubatches = 2 if self.vllm_config.parallel_config.enable_dbo else 1
        gw.init_workspace_manager(self.device, num_ubatches)
        from mock_gpu.counters import wrap
        from mock_gpu.runner import MockGPUModelRunner

        self.model_runner = MockGPUModelRunner(self.vllm_config, self.device)
        for _m in (
            "_update_states",
            "_prepare_inputs",
            "_preprocess",
            "_bookkeeping_sync",
        ):
            if not getattr(MockGPUModelRunner, _m + "_wrapped", False):
                wrap(MockGPUModelRunner, _m)
                setattr(MockGPUModelRunner, _m + "_wrapped", True)
        print(
            f"[mock_gpu] runner ready (world_size={self.parallel_config.world_size})",
            flush=True,
        )

    def determine_available_memory(self):
        return 8 * 1024 ** 3

    def compile_or_warm_up_model(self):
        from vllm.config.compilation import CUDAGraphMode
        from vllm.v1.worker.worker_base import CompilationTimes

        cc = self.vllm_config.compilation_config
        if cc.cudagraph_mode != CUDAGraphMode.NONE:
            try:
                self.model_runner.capture_model()
                print("[mock_gpu] cudagraph captured (fake device)", flush=True)
            except Exception as exc:
                import traceback

                traceback.print_exc()
                print(f"[mock_gpu] CUDAGRAPH UNAVAILABLE: {exc}", flush=True)
                cc.cudagraph_mode = CUDAGraphMode.NONE
                try:
                    self.model_runner.cudagraph_dispatcher.initialize_cudagraph_keys(
                        CUDAGraphMode.NONE,
                        self.model_runner.uniform_decode_query_len,
                    )
                except Exception:
                    pass
        return CompilationTimes(0.0, 0.0)

    Worker.init_device = init_device
    Worker.determine_available_memory = determine_available_memory
    Worker.load_model = lambda self, **kwargs: None
    Worker.compile_or_warm_up_model = compile_or_warm_up_model
    print("[mock_gpu] worker patched", flush=True)
