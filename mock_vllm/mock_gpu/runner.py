import os
import time

import torch

from mock_gpu import dispatch, worker_patch

_AUDIT = dispatch._AUDIT
_DELAY_MS = float(os.environ.get("MOCK_DELAY_MS", "0") or 0)
_CPU_SAMPLER = os.environ.get("MOCK_CPU_SAMPLER", "0") == "1"


class FakeAttentionBuilder:
    supports_update_block_table = False

    def build(self, *args, **kwargs):
        return None

    def build_for_cudagraph_capture(self, *a, **k):
        return None

    def __getattr__(self, name):
        return None


class FakeAttentionBackend:
    forward_includes_kv_cache_update = True
    block_size = 16

    @staticmethod
    def get_builder_cls():
        return FakeAttentionBuilder

    def __getattr__(self, name):
        return None




class RealAttnGroup:
    def __init__(self, backend, layer_names, vllm_config, kv_cache_spec, device, n_ubatches=1):
        self.backend = backend
        self.layer_names = layer_names
        builder_cls = backend.get_builder_cls()
        self.builders = [
            builder_cls(kv_cache_spec, layer_names, vllm_config, device)
            for _ in range(max(1, n_ubatches))
        ]
        from mock_gpu.counters import wrap
        for b in self.builders:
            wrap(b, "build", "meta:build")
            wrap(b, "update_block_table", "meta:update")

    def get_metadata_builder(self, ubid=0):
        return self.builders[ubid]

class FakeAttentionGroup:
    layer_names = ["mock.layer"]

    def __init__(self):
        self.backend = FakeAttentionBackend()
        self.builders = [FakeAttentionBuilder()]

    def get_metadata_builder(self, ubid=0):
        return self.builders[0]




class FakeModel(torch.nn.Module):
    """Stands in for the model; forward is device work, so only it is faked.

    lm_head and the logits path are the real vLLM modules: the weight is an
    untouched torch.empty, and the only substituted call is the GEMM itself.
    """

    def __init__(self, vllm_config):
        super().__init__()
        from vllm.model_executor.layers.logits_processor import LogitsProcessor
        from vllm.model_executor.layers.vocab_parallel_embedding import ParallelLMHead

        mc = vllm_config.model_config
        self.hidden_size = mc.get_hidden_size()
        self.vocab_size = mc.get_vocab_size()
        self.dtype = mc.dtype
        self._hidden_buf = None
        self.lm_head = ParallelLMHead(
            self.vocab_size,
            self.hidden_size,
            params_dtype=self.dtype,
            quant_config=vllm_config.quant_config,
            prefix="lm_head",
        )
        self.logits_processor = LogitsProcessor(self.vocab_size)

    def forward(self, input_ids=None, positions=None, intermediate_tensors=None,
                inputs_embeds=None, **kwargs):
        torch.cuda.synchronize()
        n = inputs_embeds.shape[0] if inputs_embeds is not None else (
            input_ids.shape[0] if input_ids is not None else 1)
        buf = self._hidden_buf
        if buf is None or buf.shape[0] < n:
            buf = torch.empty((n, self.hidden_size), dtype=self.dtype)
            self._hidden_buf = buf
        return buf[:n]

    def compute_logits(self, hidden_states, *a, **k):
        return self.logits_processor(self.lm_head, hidden_states)

    def __getattr__(self, name):
        return super().__getattr__(name)


from vllm.v1.kv_cache_interface import FullAttentionSpec
from vllm.v1.worker.gpu_model_runner import GPUModelRunner


_REAL_MODEL = os.environ.get("MOCK_PREFILL", "1") != "0"


class MockGPUModelRunner(GPUModelRunner):
    def __init__(self, vllm_config, device):
        super().__init__(vllm_config, device)
        self.model = self._build_real_model() if _REAL_MODEL else FakeModel(vllm_config)
        from vllm.config.compilation import CUDAGraphMode

        mode = vllm_config.compilation_config.cudagraph_mode
        if mode is not None and mode != CUDAGraphMode.NONE and mode.has_full_cudagraphs():
            from vllm.compilation.cuda_graph import CUDAGraphWrapper

            self.model = CUDAGraphWrapper(
                self.model, vllm_config, runtime_mode=CUDAGraphMode.FULL
            )

    def _build_real_model(self):
        """Construct and load the real model on CPU, with device leaves faked.

        Startup is outside the profile window, but everything base does on the
        host happens here too: construction, checkpoint loading, and the
        quant post-load. Only the device-side H2D copies are replaced.
        """
        from mock_gpu import worker_patch
        from vllm.model_executor.model_loader import get_model_loader
        from vllm.model_executor.model_loader.utils import (
            initialize_model,
            process_weights_after_loading,
        )
        from vllm.utils.torch_utils import set_default_torch_dtype

        # BaseModelLoader brackets construction, weight loading and post-load
        # in this context; skipping it leaves unquantized params (embed,
        # lm_head, norms) at torch's default fp32 instead of the model dtype.
        with (
            set_default_torch_dtype(self.model_config.dtype),
            worker_patch.weight_load_phase(),
        ):
            model = initialize_model(self.vllm_config)
            get_model_loader(self.vllm_config.load_config).load_weights(
                model, self.model_config
            )
            with worker_patch.weight_post_load():
                process_weights_after_loading(
                    model, self.model_config, torch.device("cpu")
                )
        return model

    def _init_device_properties(self):
        self.num_sms = 64

    def get_kv_cache_spec(self):
        if _REAL_MODEL:
            return super().get_kv_cache_spec()
        cfg = self.model_config.hf_text_config
        nkv = getattr(cfg, "num_key_value_heads", 8) or 8
        hs = getattr(cfg, "head_dim", None)
        if not hs:
            hs = getattr(cfg, "hidden_size", 4096) // max(
                1, getattr(cfg, "num_attention_heads", 32)
            )
        return {
            "mock.layer": FullAttentionSpec(
                block_size=16,
                num_kv_heads=int(nkv),
                head_size=int(hs),
                dtype=self.model_config.dtype,
            )
        }

    def initialize_kv_cache(self, kv_cache_config, *args, **kwargs):
        if _REAL_MODEL:
            return super().initialize_kv_cache(kv_cache_config, *args, **kwargs)
        self.kv_cache_config = kv_cache_config
        from vllm.v1.attention.backends.ilu_flash_attn import (
            IluFlashAttentionBackend,
        )
        from vllm.v1.kv_cache_interface import UniformTypeKVCacheSpecs

        n_ubatches = 2 if self.vllm_config.parallel_config.enable_dbo else 1
        groups = []
        for g in kv_cache_config.kv_cache_groups:
            spec = g.kv_cache_spec
            if isinstance(spec, UniformTypeKVCacheSpecs):
                spec = spec.kv_cache_specs.get("mock.layer") or next(iter(spec.kv_cache_specs.values()))
            groups.append([RealAttnGroup(
                IluFlashAttentionBackend,
                ["mock.layer"],
                self.vllm_config,
                spec,
                self.device,
                n_ubatches,
            )])
        self.attn_groups = groups
        # vLLM computes this in initialize_metadata_builders, which the mock
        # bypasses; without it _may_reorder_batch skips its per-step work.
        self.calculate_reorder_batch_threshold()

        from vllm.config.compilation import CUDAGraphMode

        mode = self.vllm_config.compilation_config.cudagraph_mode
        if mode is None or mode != CUDAGraphMode.NONE:
            self._check_and_update_cudagraph_mode(
                [{IluFlashAttentionBackend}], kv_cache_config.kv_cache_groups
            )

    def get_supported_generation_tasks(self):
        return ["generate"]

    def execute_model(self, scheduler_output, intermediate_tensors=None):
        if not _AUDIT:
            return super().execute_model(scheduler_output, intermediate_tensors)
        with dispatch.active("execute", audit_only=True):
            out = super().execute_model(scheduler_output, intermediate_tensors)
        dispatch.dump_audit_if_due()
        return out

    def sample_tokens(self, grammar_output=None):
        if not _AUDIT:
            return super().sample_tokens(grammar_output)
        with dispatch.active("sample_tokens", audit_only=True):
            return super().sample_tokens(grammar_output)

    def _sample(self, logits, spec_decode_metadata):
        if _CPU_SAMPLER:
            return super()._sample(logits, spec_decode_metadata)
        if _AUDIT:
            with dispatch.active("sample", audit_only=True), worker_patch.sample_phase():
                return super()._sample(logits, spec_decode_metadata)
        worker_patch._SAMPLE_PHASE = True
        try:
            return super()._sample(logits, spec_decode_metadata)
        finally:
            worker_patch._SAMPLE_PHASE = False

    def _prepare_inputs(self, scheduler_output, *args, **kwargs):
        if _AUDIT:
            with dispatch.active("prepare", audit_only=True):
                out = super()._prepare_inputs(scheduler_output, *args, **kwargs)
        else:
            out = super()._prepare_inputs(scheduler_output, *args, **kwargs)
        if _DELAY_MS > 0:
            time.sleep(_DELAY_MS / 1000.0)
        return out


if not _AUDIT:
    # These overrides exist only to scope auditing; without it, use the real
    # methods so the profile shows base's frames and no extra wrapper.
    MockGPUModelRunner.execute_model = GPUModelRunner.execute_model
    MockGPUModelRunner.sample_tokens = GPUModelRunner.sample_tokens
    if _DELAY_MS <= 0:
        MockGPUModelRunner._prepare_inputs = GPUModelRunner._prepare_inputs
