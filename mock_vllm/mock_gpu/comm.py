try:
    from vllm.distributed.device_communicators.base_device_communicator import (
        DeviceCommunicatorBase as _Base,
    )
    from vllm.iluvatar.distributed.device_communicators.ilu_cuda_communicator import (
        IluCudaCommunicator as _IluComm,
    )
except Exception:  # different vLLM build

    class _Base:  # type: ignore[no-redef]
        pass

    class _IluComm(_Base):  # type: ignore[no-redef]
        pass


class _IxfdGroup:
    """Stands in for the ixformer communicator handle.

    ixfd._check_group passes anything that is not a torch ProcessGroup
    straight through, so every wrapper keeps its real code path and only the
    pybind call at the bottom is replaced.
    """


class StubDeviceComm(_IluComm):
    """Device communicator that keeps the ixformer call chain, not the device.

    The real IluCudaCommunicator methods are used unchanged; what differs is
    the init (no pynccl/custom-allreduce setup) and the ixfd_group handle,
    which is a sentinel accepted by the stubbed pybind leaves.
    """

    def __init__(
        self,
        cpu_group,
        device=None,
        device_group=None,
        unique_name="",
        global_ranks=None,
        global_world_size=None,
        tcp_store_group=None,
    ):
        _Base.__init__(
            self,
            cpu_group,
            device,
            device_group,
            unique_name,
            global_ranks,
            global_world_size,
        )
        self.use_custom_allreduce = False
        self.use_torch_symm_mem = False
        self.use_flashinfer_allreduce = False
        self.pynccl_comm = None
        self.ca_comm = None
        self.qr_comm = None
        self.symm_mem_comm = None
        self.fi_ar_comm = None
        self.tcp_store_group = tcp_store_group
        self.is_stateless_group = False
        self.use_vllm_comm = True
        self.ixfd_group = _IxfdGroup()

    def destroy(self):
        return None
