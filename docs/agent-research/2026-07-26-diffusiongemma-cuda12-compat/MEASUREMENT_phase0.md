# Phase 0 — DiffusionGemma VRAM measurement (RESOLVED, 2026-07-26)

**Box:** BMD-LC-01 · RTX 5000 Ada (32 GB) · driver **565.57.01** (CUDA 12.7, frozen) · Ubuntu 22.04.

## Software resolution — no source build, driver untouched
The blocker was never the driver; it was a torch built for a *newer major* CUDA.
- **Ran on 565 via CUDA minor-version compatibility:** a CUDA-12.9 build runs on a 12.7 driver
  (same major 12; only ≥525 required). Verified empirically: `torch 2.11.0+cu129` allocates on the GPU.
  (agy's "cu129 needs ≥570" conflated *recommended* with *minimum* driver — wrong.)
- **Working stack (all `+cu129`):** `vllm 0.26.0+cu129` (prebuilt `cp38-abi3` wheel from the GH
  release), `torch 2.11.0`, `torchvision 0.26.0`, `torchaudio 2.11.0`. The torch *trio* must all be
  cu129 or vLLM import dies (`torchvision::nms` / `_torchaudio.abi3.so`).
- **NOT usable:** the default PyPI `vllm`/`torch` are `cu130` (CUDA 13, needs driver ≥580) → dies at
  `_cuda_init`. And `nvidia/...-NVFP4` is Blackwell-only (Ada lacks 5th-gen tensor cores) — dead end.

## The measurement (RedHatAI/diffusiongemma-26B-A4B-it-FP8-dynamic)
- **FP8 weights resident ≈ 26.3 GiB** (hard floor). Load time 7.3 s.
- On the 32 GB card that leaves **~5 GiB** to split between KV cache and the diffusion state buffers.
- **vLLM's profiler does NOT reserve for the diffusion buffers** (canvas×vocab×seqs, ~1.5 GiB), which
  allocate *outside* the `gpu-memory-utilization` budget → a narrow viable util window:
  - util 0.95 → KV 3.6 GiB but **OOM** on the un-profiled diffusion buffers.
  - util 0.85 → diffusion headroom OK but KV starved to 0.45 GiB (< 1.14 needed for 8k).
  - **util 0.90 → boots.** KV 2.03 GiB / 14,614 tokens, max concurrency 1.78×, **30.9 GB resident**.
- **Smoke test PASSED:** `/v1/models` lists the model; a `/v1/chat/completions` returns `OK`
  (finish_reason=stop) — tool-call/reasoning parsers (`gemma4`) load fine.

### Working serve command (reproducible)
```bash
VLLM_USE_V2_MODEL_RUNNER=1 PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  vllm serve RedHatAI/diffusiongemma-26B-A4B-it-FP8-dynamic \
  --port 11435 --trust-remote-code \
  --max-num-seqs 1 --max-model-len 8192 --gpu-memory-utilization 0.90 \
  --enforce-eager --enable-chunked-prefill \
  --hf-overrides '{"diffusion_sampler":"entropy_bound","diffusion_entropy_bound":0.1}' \
  --diffusion-config '{"canvas_length":256}' \
  --enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4
```

## Decision table (gates Phases 2/3)
| Question | Answer |
|---|---|
| Does FP8 run on the frozen 565 driver? | **Yes** (cu129 stack, minor-version compat). |
| Fits the 32 GB card **alone**? | **Yes** — 30.9 GB resident at util 0.90. |
| Context ceiling at FP8 on this card? | **~8k tokens** (KV starved by 26 GB weights). Larger context needs a smaller quant. |
| Co-reside with a resident Ollama model? | **No** — 26 GB weights leave no room for a 15–23 GB Ollama model. |
| **Phase 3 GPU mux (`gpu-switch`) needed?** | **YES** — diffusion and Ollama are mutually exclusive on the GPU. |
| `--enforce-eager` required? | Yes at this tightness (CUDA-graph private pool overflows otherwise). |

## Open follow-ups
- If 8k context is too small: hunt an **INT4/AWQ/GPTQ** DiffusionGemma that vLLM+Ada can serve
  (~13 GB weights → roomy KV + possible Ollama co-residency, would obviate the mux). NVFP4 stays out.
- Phase 2: wrap the working command as a `Type=notify` systemd unit on :11435 (+ `ufw allow`).
- Pin the venv: `pip freeze` the cu129 trio + vllm so the stack is reproducible.
