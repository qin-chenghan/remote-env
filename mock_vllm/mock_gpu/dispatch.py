"""Operator stub layer.

Handlers replace aten ops that would reach the device. Each handled op is
counted as '<phase>:<op>'. Audit mode (MOCK_AUDIT=1) additionally records the
largest tensor each unhandled op touches, so big CPU fallbacks can be spotted.
"""
import atexit
import contextlib
import os

import torch

_PHASE = os.environ.get("MOCK_PHASE", "all")
_AUDIT = os.environ.get("MOCK_AUDIT", "0") == "1"
_DEBUG_INDEX = os.environ.get("MOCK_DEBUG_INDEX", "0") == "1"
_AUDIT_OPS = {}
_AUDIT_TRACES = {}
_DBG_COUNT = {}


def phase():
    return _PHASE


def auditing():
    return _AUDIT


def set_phase(name):
    global _PHASE
    _PHASE = name


@contextlib.contextmanager
def active(name, audit_only=False):
    """Enter the stub layer.

    audit_only scopes only need interception while auditing; entering a
    TorchDispatchMode charges every op, so hot scopes stay clean otherwise.
    """
    global _PHASE
    prev = _PHASE
    _PHASE = name
    try:
        if _AUDIT or not audit_only:
            with MockOpMode():
                yield
        else:
            yield
    finally:
        _PHASE = prev


def _note_audit(func, args, ns=0):
    elems = 0
    for a in args:
        if isinstance(a, torch.Tensor):
            elems = max(elems, a.numel())
    key = (str(func), _PHASE)
    calls, prev, total = _AUDIT_OPS.get(key, (0, 0, 0))
    _AUDIT_OPS[key] = (calls + 1, max(prev, elems), total + ns)
    if _DEBUG_INDEX and str(func).startswith("aten.index"):
        if _DBG_COUNT.get(key, 0) < 10:
            _DBG_COUNT[key] = _DBG_COUNT.get(key, 0) + 1
            shapes = [
                (tuple(a.shape), str(a.dtype).replace("torch.", ""), a.numel())
                for a in args
                if isinstance(a, torch.Tensor)
            ]
            print(
                f"[mock_gpu][idxdbg] {_PHASE} {func} {ns / 1000.0:.1f}us "
                f"threads={torch.get_num_threads()} {shapes}",
                flush=True,
            )
    if elems >= 4096 and key not in _AUDIT_TRACES:
        import traceback

        frames = traceback.extract_stack()[-9:-1]
        _AUDIT_TRACES[key] = [
            f"{os.path.basename(f.filename)}:{f.lineno} {f.name}" for f in frames
        ]


class MockOpMode(torch.utils._python_dispatch.TorchDispatchMode):
    handlers = {}

    def __torch_dispatch__(self, func, types, args=(), kwargs=None):
        kwargs = kwargs or {}
        handler = self.handlers.get(func)
        if handler is None:
            if _AUDIT:
                import time

                t0 = time.perf_counter_ns()
                out = func(*args, **kwargs)
                _note_audit(func, args, time.perf_counter_ns() - t0)
                return out
            return func(*args, **kwargs)
        try:
            from mock_gpu.counters import bump

            bump(f"{_PHASE}:{func}")
        except Exception:
            pass
        return handler(func, args, kwargs)


def _argmax(func, args, kwargs):
    t = args[0]
    dim = args[1] if len(args) > 1 else kwargs.get("dim")
    if dim is None:
        return torch.zeros((), dtype=torch.int64)
    shape = list(t.shape)
    if isinstance(dim, int):
        shape.pop(dim)
    return torch.zeros(shape, dtype=torch.int64)


def _big_to_copy(func, args, kwargs):
    if args and getattr(args[0], "numel", lambda: 0)() >= 1_000_000:
        return args[0]
    return func(*args, **kwargs)


MockOpMode.handlers.update({
    torch.ops.aten.argmax.default: _argmax,
    torch.ops.aten._to_copy.default: _big_to_copy,
})


def register(op, handler):
    MockOpMode.handlers[op] = handler


_ORIG_TENSOR_ARGMAX = torch.Tensor.argmax


def _stub_argmax(self, dim=None, keepdim=False, *a, **k):
    """Keep the aten::argmax frame; reduce over one column instead of the vocab.

    A full-vocab argmax is a real million-element reduction on CPU (ms per
    step at bs8), but its output is only the token id, which the mock never
    reads. Running aten on a one-column view keeps the same output shape and
    the aten frame at a few microseconds.
    """
    if dim is None or not isinstance(dim, int):
        return torch.zeros((), dtype=torch.int64)
    d = dim + self.dim() if dim < 0 else dim
    return _ORIG_TENSOR_ARGMAX(self.narrow(d, 0, 1), dim=d, keepdim=keepdim)


def install_method_stubs():
    """Method-level stubs cost nothing for ops left alone; no dispatch mode."""
    if getattr(torch.Tensor.argmax, "_mock_stub", False):
        return
    torch.Tensor.argmax = _stub_argmax
    _stub_argmax._mock_stub = True
    torch.argmax = lambda input, dim=None, keepdim=False, *a, **k: _stub_argmax(
        input, dim, keepdim
    )


def _dump_audit():
    if not _AUDIT or not _AUDIT_OPS:
        return
    rows = sorted((t, e, c, p, o) for (o, p), (c, e, t) in _AUDIT_OPS.items())
    print("\n[mock_gpu][audit] total_us calls max_elems phase op (top 40)", flush=True)
    for t, e, c, p, o in rows[-40:][::-1]:
        print(f"[mock_gpu][audit] {t / 1000.0:>10.1f} {c:>6d} {e:>10d} {p:<14s} {o}", flush=True)
    print("[mock_gpu][audit] stacks for >=65536 elements:", flush=True)
    for (o, p), stack in _AUDIT_TRACES.items():
        print(f"[mock_gpu][audit] {p} {o}", flush=True)
        for s in stack:
            print(f"[mock_gpu][audit]     {s}", flush=True)


_AUDIT_CALLS = [0]


def dump_audit_if_due(limit=6):
    """Print the audit snapshot at fixed step counts (engine exits by SIGTERM)."""
    if not _AUDIT:
        return
    _AUDIT_CALLS[0] += 1
    if _AUDIT_CALLS[0] in (limit, limit * 4):
        _dump_audit()


atexit.register(_dump_audit)


def install():
    """Enable interception for one process-wide scope; caller owns the context."""
    return MockOpMode()
