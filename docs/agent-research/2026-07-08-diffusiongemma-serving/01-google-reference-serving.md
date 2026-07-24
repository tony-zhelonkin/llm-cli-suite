# DiffusionGemma — Official Reference Serving

**Summary:** DiffusionGemma ships with an official HF Transformers path (`DiffusionGemmaForBlockDiffusion` + `AutoProcessor`) AND day-zero native vLLM support that exposes a standard OpenAI-compatible `/v1` HTTP server, so a custom FastAPI shim is NOT required — diffusion-specific knobs are passed as server-side `--hf-overrides` config, not per-request generate kwargs.

**Confidence / sources:** Medium-high on the shape of the serving story; the model is ~4 weeks old (released 2026-06-10) and is post my training cutoff, so all specifics below come from live web sources fetched 2026-07-08, not prior knowledge. Exact numeric defaults and class names should be re-verified against the repo before relying on them in code. Primary sources:
- HF model card: https://huggingface.co/google/diffusiongemma-26B-A4B-it
- Google AI model card: https://ai.google.dev/gemma/docs/diffusiongemma/model_card
- Google Developers Blog guide: https://developers.googleblog.com/diffusiongemma-the-developer-guide/
- vLLM blog (native dLLM support): https://vllm-project.github.io/2026/06/10/diffusion-gemma
- vLLM recipe: https://recipes.vllm.ai/Google/diffusiongemma-26B-A4B-it
- DeepMind gemma repo (referenced): https://github.com/google-deepmind/gemma (diffusion subdir)

Flagged uncertainties are marked **[UNVERIFIED]** below.

---

## 1. Official reference inference code

**Two official paths, both confirmed by multiple sources:**

**A. HF Transformers (Python library).** The model card provides code using classes `DiffusionGemmaForBlockDiffusion` and `AutoProcessor`.
- Dependencies: `pip install -U transformers torch accelerate` (exact minimum versions not pinned in docs — **[UNVERIFIED]**; pin against the repo since the model is days-old and APIs are shifting).
- Google references "official training/inference recipes" at the DeepMind gemma repo, diffusion subdirectory: `github.com/google-deepmind/gemma` (path `gemma/diffusion` referenced but not independently confirmed — **[UNVERIFIED]**). The generic `github.com/google-gemma` link on the card is an org landing page, not a code path.
- Docs confirm compatibility claims for Transformers, vLLM, SGLang, and MLX. The Google dev guide did NOT show a concrete `generate()` snippet with the diffusion kwargs, so exact Transformers-level parameter passing is **[UNVERIFIED]**.

**B. vLLM (native).** DiffusionGemma is billed as "the first dLLM natively supported in vLLM," with day-zero support (Google collaborated on the integration via vLLM model-runner v2 `ModelState`). This is the recommended production path.

---

## 2. Diffusion sampling parameters and HOW they are passed

Documented sampler behavior (from model card):
- Max denoising steps: **48** per 256-token canvas block.
- Temperature schedule: linear decay **0.8 → 0.4**.
- Entropy bound: **0.1** (lowest-entropy tokens committed each step within this bound).
- Adaptive early-stop: triggers when average canvas entropy **< 0.005** AND top predictions are stable across consecutive steps.

**How they are passed — key finding: server-side model config, NOT per-request kwargs.** In vLLM they are set at load time:

```
--hf-overrides '{"diffusion_sampler":"entropy_bound","diffusion_entropy_bound":0.1}'
--diffusion-config '{"canvas_length":256}'
```

Offline equivalent:
```python
hf_overrides={"diffusion_sampler":"entropy_bound","diffusion_entropy_bound":0.1}
diffusion_config={"canvas_length":256}
```

- The **temperature schedule and the adaptive-stop / entropy thresholds are NOT exposed as configurable flags** in the docs seen — they appear baked into the sampler preset. Step count (48) is likewise not shown as a user flag. **[UNVERIFIED whether newer builds expose these.]**
- Implication for an OpenAI-compatible shim: standard `/v1` request fields (temperature, max_tokens, etc.) map onto vLLM's request path, but the diffusion-specific knobs must be fixed at server launch via `--hf-overrides`. You cannot vary denoising config per request through the OpenAI API surface.

---

## 3. OpenAI-compatible `/v1` HTTP API?

**Yes — confirmed.** vLLM serves DiffusionGemma through its standard OpenAI-compatible server; no custom shim needed. Confirmed serve command:

```bash
docker run -itd --name diffusiongemma \
  --ipc=host --network host --gpus all \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  vllm/vllm-openai:gemma \
    --model google/diffusiongemma-26B-A4B-it \
    --max-model-len 262144 \
    --max-num-seqs 4 \
    --gpu-memory-utilization 0.85 \
    --host 0.0.0.0 --port 8000
```

Query with the normal OpenAI client (`base_url=http://localhost:8000/v1`, `chat.completions.create`).

**Critical serving caveat:** `--max-num-seqs` must stay low (≤4, conservative 1). The diffusion state buffers pre-allocate `max_seqs × canvas_length × vocab_size` tensors, which OOM at higher concurrency. This is the opposite of normal AR serving where you push batch size up. Conservative first-deploy: `--max-num-seqs 1 --max-model-len 65536 --gpu-memory-utilization 0.75`.

(HF Transformers path is Python-library-only with no HTTP server — vLLM/SGLang is the API route.)

---

## 4. VRAM footprint / hardware

- Model: 25.2B total / 3.8B active MoE + ~550M vision encoder params.
- **Quantized deployment fits within ~18 GB VRAM** (consumer RTX 5090 / 4090, 24GB class) — the "18GB variant" in the task. The specific quant scheme/name and a byte-level breakdown are **NOT documented [UNVERIFIED]**; only the "quantized within 18GB" claim and FP8 perf numbers appear.
- FP8 throughput: ~1,288 tok/s on H200, ~1,008 tok/s on H100; ~700+ tok/s on RTX 5090. These reflect the compute-bound (not memory-bound) decode profile.
- Reference/benchmark GPUs: single H100/H200; no multi-GPU serve command published. GGUF is NOT shipped by Google (a third-party `unsloth/...-GGUF` exists but is unofficial).

---

## 5. Multimodal input handling (serving-relevant)

- Inputs: **text + image + video**; output is text only. Audio is NOT supported (diffusion checkpoints lack an audio encoder).
- Images: variable aspect ratio/resolution with configurable visual token budgets — **70 / 140 / 280 / 560 / 1120** soft tokens. Model card recommends placing image content BEFORE text in the prompt.
- Video: up to 60 seconds at 1 fps.
- vLLM multimodal flags:
  ```
  --mm-processor-kwargs '{"max_soft_tokens":1120}'
  --limit-mm-per-prompt '{"image":7}'
  ```
- Transformers path uses `AutoProcessor` to handle the multimodal preprocessing.

---

## Bottom line for our suite

If we serve DiffusionGemma we should use **vLLM's built-in OpenAI-compatible server**, not build a FastAPI shim. Diffusion sampler config is fixed at launch via `--hf-overrides`; per-request control is limited to standard OpenAI params. Plan for **low concurrency (`--max-num-seqs` ≤4)** and a ~18GB quantized footprint on 24GB-class GPUs. Re-verify class names, quant details, and exposed knobs directly against the HF repo / DeepMind gemma repo before coding, since the release is only weeks old.
