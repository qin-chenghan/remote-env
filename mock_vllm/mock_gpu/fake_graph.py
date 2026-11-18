import contextlib

import torch

import mock_gpu
from mock_gpu import counters


def _compiled_replay():
    """Give replay the frame base records: torch/cuda/graphs.py(141): replay.

    Instantiating the executor entries shows this python frame in the base
    trace (CUDAGraph.replay, a thin wrapper over the pybind replay). Compiling
    the stub at the same file/line makes the profiled frame name identical;
    the body is inlined because any helper would add a frame of its own.

    The sync stands in for the per-step device wait the measurement tool
    expects inside the graph scope; the launch keeps the ledger's graph-call
    count intact.
    """
    import torch.cuda.graphs as tg

    code = tg.CUDAGraph.replay.__code__
    src = "\n" * (code.co_firstlineno - 1) + (
        "def replay(self) -> None:\n"
        "    self._replays += 1\n"
        "    if _counters.ENABLED:\n"
        "        _counters.bump('graph:replay')\n"
        "    launch = _mock_gpu.worker_patch._GRAPH_LAUNCH\n"
        "    if launch is not None:\n"
        "        launch(0, 0)\n"
        "    _torch.cuda.synchronize()\n"
    )
    ns = {"_counters": counters, "_mock_gpu": mock_gpu, "_torch": torch}
    exec(compile(src, code.co_filename, "exec"), ns)
    return ns["replay"]


class _FakeGraph:
    replay = _compiled_replay()

    def __init__(self, *args, **kwargs):
        self._capturing = False
        self._replays = 0

    def capture_begin(self, pool=None, capture_error_mode="global"):
        self._capturing = True

    def capture_end(self):
        self._capturing = False

    def reset(self):
        self._replays = 0

    def pool(self):
        return _GLOBAL_POOL

    def register_generator_state(self, *args, **kwargs):
        pass


class _FakeGraphPool:
    pass


_GLOBAL_POOL = _FakeGraphPool()


def graph_pool_handle(*args, **kwargs):
    return _GLOBAL_POOL


def graph(cuda_graph=None, pool=None, stream=None, capture_error_mode="global"):
    g = cuda_graph if cuda_graph is not None else _FakeGraph()
    return contextlib.nullcontext(g)


def install(torch_cuda):
    torch_cuda.CUDAGraph = _FakeGraph
    torch_cuda.graph = graph
    torch_cuda.graph_pool_handle = graph_pool_handle
