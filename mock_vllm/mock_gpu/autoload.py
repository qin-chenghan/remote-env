import os


def _no_gpu() -> bool:
    if os.environ.get("CUDA_VISIBLE_DEVICES") == "-1":
        return True
    return not os.path.exists("/dev/iluvatar0")


class _MockGraphPool:
    pass


def _patch_platform() -> None:
    from vllm.platforms import current_platform

    cls = type(current_platform)
    if getattr(cls, "_mock_gpu_patched", False):
        return
    orig = cls.check_and_update_config.__func__

    def check_and_update_config(c, vllm_config):
        orig(c, vllm_config)
        vllm_config.device_config.device = "cpu"
        try:
            vllm_config.compilation_config.enable = False
        except Exception:
            pass
        if os.environ.get("MOCK_EAGER", "0") == "1":
            try:
                from vllm.config.compilation import CUDAGraphMode

                vllm_config.compilation_config.cudagraph_mode = CUDAGraphMode.NONE
            except Exception:
                pass
            try:
                vllm_config.model_config.enforce_eager = True
            except Exception:
                pass

    cls.check_and_update_config = classmethod(check_and_update_config)
    cls.is_pin_memory_available = classmethod(lambda c: False)
    cls.get_device_communicator_cls = classmethod(
        lambda c: "mock_gpu.comm.StubDeviceComm"
    )
    cls.get_current_memory_usage = classmethod(lambda c, device=None: 0.0)
    cls.get_device_total_memory = classmethod(lambda c, device_id=0: 8 * 1024 ** 3)
    cls.graph_pool_handle = classmethod(lambda c: _MockGraphPool())
    cls._mock_gpu_patched = True


def install() -> bool:
    if not _no_gpu():
        return False
    os.environ["VLLM_ENFORCE_CUDA_GRAPH"] = "1"
    try:
        import vllm.v1.worker.gpu_worker as gw
    except Exception as e:
        print(f"[mock_gpu] skipped: {e}")
        return False
    from mock_gpu.worker_patch import patch_worker

    _patch_platform()
    patch_worker(gw)

    print("[mock_gpu] activated: no Iluvatar device visible")
    return True


ACTIVE = install()
