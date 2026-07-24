# Serving DiffusionGemma behind an OpenAI-compatible API — inference server landscape

*Research date: 2026-07-08. Model in scope: `google/diffusiongemma-26B-A4B-it` (discrete block-diffusion / denoising decoding, Gemma 4 MoE backbone, safetensors).*

## Verdict (one line)

**Yes — it is servable today: both vLLM and SGLang ship native DiffusionGemma support behind a standard OpenAI `/v1/chat/completions` server, but diffusion-specific sampling is configured at server launch, NOT per-request via `extra_body`. TGI does not support it.**

## Comparison table

| Server | Supports diffusion/denoising decoding | Supports DiffusionGemma (Gemma 4 MoE diffusion) specifically | Native OpenAI `/v1` server | Diffusion params via OpenAI API? | Maturity (2026-07) |
|---|---|---|---|---|---|
| **vLLM** | Yes (implemented by reusing the speculative-decoding path) | Yes — "first dLLM natively supported in vLLM", blog 2026-06-10, plus official recipe | Yes (`vllm serve` → `/v1`) | No per-request; set at launch via `--hf-overrides` / `--diffusion-config`. Only standard params + `chat_template_kwargs` seen per-request | New but official; day-zero-class support. Requires `TRITON_ATTN`, chunked prefill; ~60GB+ VRAM unquantized |
| **SGLang** | Yes (`--dllm-algorithm`: `LowConfidence`, `JointThreshold`, `Gemma4Renoise`) | Yes — dedicated `Gemma4Renoise` algorithm + cookbook page | Yes (`sglang serve` → `/v1/chat/completions`) | No per-request. Set at launch (`--dllm-algorithm`, `--dllm-algorithm-config` YAML). Standard `temperature/top_k/top_p` accepted but **ignored**; `logprobs`/penalties/logit_bias/grammar **rejected (HTTP 400)** | New but official; specialized. Auto-selects Triton attn + eager mode; streaming = one canvas per chunk |
| **HF TGI** | No evidence of any diffusion/denoising support | No | Yes (for autoregressive models) | N/A | TGI team now explicitly redirects users to vLLM/SGLang; DiffusionGemma absent from every support list |
| **Diffusion-LLM-specific / other** | Varies (see below) | Mostly no | Mercury (commercial) yes; open self-host options immature | Mercury: `reasoning_effort` etc. via OpenAI API | Mixed — see "Emerging frameworks" |

---

## Per-server findings

### 1. vLLM — CONFIRMED SUPPORTED

- **Diffusion decoding:** Yes. The vLLM blog "DiffusionGemma: The First Diffusion LLM (dLLM) Natively Supported in vLLM" (dated 2026-06-10) states DiffusionGemma is the first dLLM natively supported, implemented by **reusing vLLM's mature speculative-decoding path** — each denoising step's canvas is treated as a large block of draft tokens that is fully accepted/rejected. "The scheduler, model runner, and Gemma4 backbone are reused unchanged, and only the `ModelState` and sampler are diffusion-specific." Support for sampling 0 tokens was added (vs. the usual speculative "bonus token").
- **Model-specific:** Yes — DiffusionGemma is the flagship integration; an official recipe exists (`recipes.vllm.ai/Google/diffusiongemma-26B-A4B-it`). Google's own materials list vLLM as day-zero.
- **OpenAI `/v1`:** Yes. Recipe shows `vllm serve google/diffusiongemma-26B-A4B-it ...` then `OpenAI(base_url="http://localhost:8000/v1", api_key="EMPTY")` against `/v1/chat/completions`.
- **Diffusion params passing:** Configured **at launch**, not per-request. Example launch flags from the recipe:
  ```
  vllm serve google/diffusiongemma-26B-A4B-it \
    --max-model-len 262144 --max-num-seqs 4 --gpu-memory-utilization 0.85 \
    --attention-backend TRITON_ATTN --generation-config vllm \
    --hf-overrides '{"diffusion_sampler": "entropy_bound", "diffusion_entropy_bound": 0.1}' \
    --diffusion-config '{"canvas_length": 256}' --enable-chunked-prefill
  ```
  - `--diffusion-config '{"canvas_length": 256}'` — the 256-token canvas.
  - `--hf-overrides '{"diffusion_sampler": "entropy_bound", "diffusion_entropy_bound": 0.1}'` — sampler + entropy threshold.
  - Temperature is not a single value: the model uses a per-step schedule (linear interpolation between τ_max = 0.8 and τ_min = 0.4, keyed on denoising step); adaptive stopping halts when per-token entropy is low.
  - **Per-request `extra_body`:** The only `extra_body` example in the recipe is `{"chat_template_kwargs": {"enable_thinking": True}}` (thinking toggle). **No documented way to override denoising steps / canvas / entropy per-request via `extra_body`** — treat as unsupported / launch-time-only until proven otherwise. Standard `SamplingParams(temperature, max_tokens)` work in the offline `LLM.generate()` path.
- **Caveats:** Requires `TRITON_ATTN` backend and chunked prefill; unquantized needs a >60GB GPU (H100/G4-class). Integration is very new (mid-2026). Throughput advantage is strongest at low-to-medium batch sizes; diminishing returns at high QPS (Google's own caveat).

### 2. SGLang — CONFIRMED SUPPORTED

- **Diffusion decoding:** Yes. SGLang has a generic DLLM framework with pluggable algorithms selected via `--dllm-algorithm` (`LowConfidence`, `JointThreshold`), documented for LLaDA2.0 / SDAR, plus a DiffusionGemma-specific `Gemma4Renoise` algorithm.
- **Model-specific:** Yes — cookbook page for DiffusionGemma with `--dllm-algorithm Gemma4Renoise`.
- **OpenAI `/v1`:** Yes. Cookbook launch:
  ```
  sglang serve --model-path google/diffusiongemma-26B-A4B-it \
    --dllm-algorithm Gemma4Renoise --trust-remote-code \
    --host 0.0.0.0 --port 30000
  ```
  Serves standard OpenAI `/v1/chat/completions` at `http://localhost:30000/v1`.
- **Diffusion params passing:** Launch-time only. Tuning via `--dllm-algorithm-config` YAML (`max_denoising_steps`, `entropy_bound`, `temperature_schedule`, `stopping_config`). Per-request: `temperature/top_k/top_p` are **accepted but have no effect**; `logprobs`, penalties, `logit_bias`, and grammar/structured-output are **rejected with HTTP 400**. Diffusion knobs are not per-request tunable.
- **Caveats:** Auto-selects Triton attention + eager mode + unchunked prefill. Streaming emits **one fully-denoised canvas per chunk** (not token-level). Supported DLLM family list is still small; specialized/new.

### 3. HuggingFace TGI — NOT SUPPORTED

- No evidence in any source that TGI supports diffusion/denoising decoding or DiffusionGemma. TGI is built for autoregressive models (Flash/Paged Attention).
- TGI's own docs now redirect users to downstream engines (vLLM, SGLang, llama.cpp, MLX) going forward. DiffusionGemma is absent from every official "supported frameworks" list (which name Transformers, vLLM, SGLang, MLX, Unsloth).
- Block-diffusion needs dedicated code paths (e.g. Transformers class `DiffusionGemmaForBlockDiffusion`; llama.cpp needs a separate `llama-diffusion-cli` runner — standard `llama-server` cannot generate from it). TGI has no such path.

### 4. Diffusion-LLM-specific / other servers

- **Transformers (reference):** Runs DiffusionGemma via the `DiffusionGemmaForBlockDiffusion` class + `AutoProcessor`. Reference correctness, not a production OpenAI server (no native `/v1`). Good for validation.
- **llama.cpp:** GGUF quants exist (`unsloth/diffusiongemma-26B-A4B-it-GGUF`), but generation needs the dedicated `llama-diffusion-cli` runner; standard `llama-server` (which is what provides the OpenAI shim) reportedly cannot serve it yet. So no drop-in OpenAI server via llama.cpp today. (Note: the task's "no GGUF" premise is now outdated — Unsloth GGUF and an NVIDIA NVFP4 quant exist.)
- **MLX:** Listed by Google as a supported inference framework (Apple silicon); not an OpenAI fleet-serving solution.

---

## Emerging diffusion-LLM serving frameworks worth knowing

- **Mercury / Mercury 2 (Inception Labs)** — the leading *commercial* diffusion LLM. Exposes a genuinely **OpenAI-compatible API** (`base_url="https://api.inceptionlabs.ai/v1"`, `model="mercury-2"`), 128K context, tool calling, structured output, streaming (incl. a "diffusing" draft-refinement mode), and a `reasoning_effort` param mapped through the OpenAI surface. Also available on Azure AI Foundry. This is the most mature "diffusion LLM behind OpenAI API" today — but it is hosted/commercial, not your self-hosted weights. Note: Ollama does **not** support diffusion models (would need a backend rewrite).
- **LLaDA / LLaDA2.x (open research lineage)** — open weights; the origin of masked discrete-diffusion LLMs. Now servable via SGLang's `LowConfidence`/`JointThreshold` algorithms (`inclusionAI/LLaDA2.0-mini` etc.). Historically (early–mid 2026) required custom FastAPI wrappers around the HF implementation; **do not** try `vllm.entrypoints.openai.api_server` with stock flags on raw LLaDA — masked diffusion decoding was not in stock vLLM. SGLang integration changed that for supported LLaDA2 checkpoints.
- **NVIDIA Nemotron-Labs Diffusion** — being integrated into SGLang main; notable for letting one checkpoint be served AR *or* diffusion via an algorithm-config line (block-fill denoising w/ confidence threshold).
- **`mdlm-serve`** — cited in 2026 deployment guides as a library for MDLM-family masked-diffusion models when native engine support was absent.
- **`vllm-omni`** — a vLLM subproject documenting "continuous batching for step-wise diffusion," part of the infra that made batched diffusion serving practical.

---

## Practical recommendation for a fleet behind OpenAI `/v1`

1. **Primary: vLLM** `vllm serve` with the recipe flags — most direct path to a batched OpenAI `/v1` endpoint for these exact weights. Set canvas/sampler/entropy at launch.
2. **Alternative: SGLang** `sglang serve --dllm-algorithm Gemma4Renoise` — also OpenAI `/v1`, with YAML-based diffusion tuning; expect canvas-granularity streaming and rejection of logprobs/penalties/grammar.
3. **Design constraint for clients:** because diffusion knobs are **launch-time**, expose different denoise/quality profiles as **separate served instances/model names** rather than expecting per-request `extra_body` control. Standard params (`temperature`, `max_tokens`) are the only reliably honored per-request knobs, and even `temperature` may be ignored (SGLang) or schedule-overridden (vLLM).
4. Don't plan on TGI.

## Confidence / honesty notes

- **Confirmed** from official/primary sources: vLLM native support (vLLM blog + recipe), SGLang native support (cookbook + supported-models docs), TGI non-support (absence + TGI's own redirect), Mercury OpenAI-compat (Inception).
- **Not confirmed / treat as unsupported:** per-request `extra_body` override of denoising steps/canvas/entropy on either vLLM or SGLang — no documented example found; both point to launch-time config.
- Exact version numbers for the vLLM/SGLang releases carrying this support were not pinned down here (avoid asserting a specific version). This space is bleeding-edge (mid-2026) and moving fast; re-verify before committing infra.

## Sources

- vLLM blog: https://vllm-project.github.io/2026/06/10/diffusion-gemma.html and https://vllm.ai/blog/2026-06-10-diffusion-gemma
- vLLM recipe: https://recipes.vllm.ai/Google/diffusiongemma-26B-A4B-it
- vLLM issue #18532 (LLaDA request): https://github.com/vllm-project/vllm/issues/18532
- vllm-omni continuous batching for diffusion: https://docs.vllm.ai/projects/vllm-omni/en/latest/design/feature/diffusion_continuous_batching/
- SGLang DLLM docs: https://github.com/sgl-project/sglang/blob/main/docs/supported_models/text_generation/diffusion_language_models.md
- SGLang DiffusionGemma cookbook: https://docs.sglang.io/cookbook/autoregressive/Google/DiffusionGemma
- Nemotron-Labs Diffusion (SGLang): https://huggingface.co/blog/nvidia/nemotron-labs-diffusion
- HF TGI: https://github.com/huggingface/text-generation-inference and https://huggingface.co/docs/text-generation-inference/en/index
- DiffusionGemma model card / docs: https://huggingface.co/google/diffusiongemma-26B-A4B-it , https://ai.google.dev/gemma/docs/diffusiongemma , https://huggingface.co/docs/transformers/model_doc/diffusion_gemma
- Quants: https://huggingface.co/unsloth/diffusiongemma-26B-A4B-it-GGUF , https://huggingface.co/nvidia/diffusiongemma-26B-A4B-it-NVFP4
- Mercury / Mercury 2 (Inception): https://www.inceptionlabs.ai/blog/introducing-mercury-2 , https://arxiv.org/html/2506.17298v1
- Spheron dLLM deployment guide: https://www.spheron.network/blog/deploy-diffusion-language-models-dllm-gpu-cloud-2026/
