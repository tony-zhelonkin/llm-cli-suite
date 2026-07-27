# DiffusionGemma serving — research inventory

**Why this exists.** We want to run `google/diffusiongemma-26B-A4B-it` (real diffusion-decoding
Gemma 4 MoE, HF safetensors) as a **separate endpoint** alongside the existing Ollama fleet,
without polluting the agentic-only Ollama single-source-of-truth. Ollama's engine is
autoregressive and cannot run diffusion decoding, so this is a distinct serving track behind the
same OpenAI `/v1` seam the fleet already speaks. Decisions taken up front: **on-demand single-GPU
mux**, **`config/providers/` directory refactor** for the fleet config, **research the runtime
before building** (this folder).

> ⚠️ **Provenance caveat.** DiffusionGemma released 2026-06-10, *after* the assistant's
> training cutoff. Every model-specific claim here comes from live web sources gathered by the
> research agents and carries residual uncertainty. Items flagged **UNVERIFIED** in the artifacts
> must be re-checked against the actual HF repo / vLLM docs before code is written.

## ✅ Verification log — 2026-07-22 (Step 0 gate)

Primary sources re-checked live: [vLLM recipe](https://recipes.vllm.ai/Google/diffusiongemma-26B-A4B-it),
[vLLM blog 2026-06-10](https://vllm-project.github.io/2026/06/10/diffusion-gemma.html),
[RedHatAI FP8 card](https://huggingface.co/RedHatAI/diffusiongemma-26B-A4B-it-FP8-dynamic).

- **Model exists & vLLM native path holds → no shim needed.** Official image `vllm/vllm-openai:gemma`,
  requires `VLLM_USE_V2_MODEL_RUNNER=1` and (for quants) `--trust-remote-code`. Artifact 03 shim is
  demoted to **fallback-only**.
- **Tool-calling CONFIRMED under diffusion.** Recipe ships `--enable-auto-tool-choice
  --tool-call-parser gemma4 --reasoning-parser gemma4`; "works best in thinking mode." → eligible to
  be an **agentic** provider (resolves the ADR-003 blocker in favor of agentic).
- **Diffusion knobs CONFIRMED launch-time only.** `extra_body` exposes only `chat_template_kwargs.enable_thinking`.
- **❌ VRAM claim CORRECTED.** "~18GB quantized, fits a 24GB GPU" is **wrong**. FP8 ≈ **28GB**
  (evaluated on B200/H100/H200); BF16 is 50GB+ / multi-GPU. **FP8 does not fit a 24GB card.** The
  single-GPU mux (artifact 04) is only viable if `nvidia/...-NVFP4` measures < 24GB resident on the
  target GPU — **must be measured on-box before the mux is built.** Otherwise this model requires a
  ≥40GB GPU and the Ollama-XOR-diffusion swap is unnecessary.
- **Streaming granularity** (pseudo-stream vs per-canvas) still undocumented — low risk, verify on-box.

## Artifacts

| # | File | Question it answers | Headline finding |
|---|------|--------------------|------------------|
| 01 | [`01-google-reference-serving.md`](01-google-reference-serving.md) | How does Google officially serve it? | Two paths: HF Transformers (`DiffusionGemmaForBlockDiffusion` + `AutoProcessor`) and **native vLLM `/v1`**. Diffusion knobs set at *server launch* (`--hf-overrides`/`--diffusion-config`), not per-request. ~18GB quantized on 24GB-class GPU. text/image/video, no audio. |
| 02 | [`02-inference-servers-openai-compat.md`](02-inference-servers-openai-compat.md) | Which server gives OpenAI `/v1`? | **vLLM** ("first dLLM natively supported") and **SGLang** (`Gemma4Renoise`) both work. TGI does not. Diffusion knobs are launch-time only; SGLang even ignores per-request `temperature` → expose profiles as separate model instances, not per-call params. "No GGUF" premise is now outdated but llama.cpp still needs a separate diffusion runner. |
| 03 | [`03-openai-v1-shim-design.md`](03-openai-v1-shim-design.md) | If we must hand-roll a shim? | Copy-pasteable ~150-line FastAPI sketch: OpenAI chat in → `model_generate()` stub → OpenAI/SSE out. Diffusion defaults live server-side in a frozen dataclass, never client-accepted. **Fallback only** if the vLLM native path doesn't hold up. |
| 04 | [`04-single-gpu-ondemand-mux.md`](04-single-gpu-ondemand-mux.md) | How to share one GPU? | MVP = explicit `gpu-switch` CLI + `Type=notify` systemd unit for the diffusion server. Free Ollama VRAM via `keep_alive:0` / `ollama stop` / `OLLAMA_KEEP_ALIVE=0`, but **verify with `nvidia-smi`** (keep_alive:0 is a no-op unless it names the loaded model). Single mutex-guarded switch can never double-load. |

## Synthesized recommendation (pending your confirmation)

1. **Runtime → vLLM native OpenAI server.** If artifact 01/02's claim of day-zero vLLM support
   holds on verification, we get an OpenAI `/v1` endpoint for free and **skip the custom shim
   entirely**. The shim (artifact 03) stays on the shelf as the fallback if vLLM support is
   thinner than reported. → *Next action: verify vLLM support against the live repo/docs before
   committing.*
2. **GPU → `gpu-switch` MVP.** Single mutex CLI + systemd `Type=notify` diffusion unit; arbiter
   confirms VRAM freed via `nvidia-smi`, not the API alone. Defer the auto-routing proxy.
3. **Config → new `diffusion` provider** in the forthcoming `config/providers/` layout, its own
   policy header, `baseUrl` rewritten from a `DIFFUSION_HOST` env var (parallel to `OLLAMA_HOST`),
   served on port `11435`. Diffusion sampling profile is baked into the vLLM launch flags — it
   never appears in the model-list JSON.

## Open items before build

- [x] ~~**Verify** vLLM serves this exact model today~~ → **DONE 2026-07-22.** Confirmed (see verification log).
- [x] ~~Confirm tool-calling under diffusion~~ → **DONE.** Confirmed via `gemma4` tool-call/reasoning parsers.
- [ ] **NEW / BLOCKING: measure real resident VRAM** of `nvidia/...-NVFP4` on the target GPU. The
      "18GB" figure was wrong (FP8 ≈ 28GB). This decides whether the single-GPU mux is needed **or
      even possible** on a 24GB card. Everything in artifact 04 is gated on this number.
- [ ] Confirm pseudo-streaming render is acceptable to the Pi UI (low risk).
- [x] ~~Decide agentic vs chat-only~~ → leaning **agentic** now that tool-calling is confirmed; ratify
      in ADR-003 after a live tool-call smoke test.
