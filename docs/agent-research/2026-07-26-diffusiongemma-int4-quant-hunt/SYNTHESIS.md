# Synthesis — can DiffusionGemma get a real agentic context on this Ada box?

Sources: `report_1_ada-servable-int4-quant.md` (agy), `ref_redhat-fp8-modelcard-analysis.md`
(RedHat model card, primary), plus the Phase 0 measurement.

## The core distinction (which resolves the apparent contradiction)
- **Quantizing DiffusionGemma to 4-bit IS possible.** llm-compressor has explicit diffusion support
  (`CalibrationDiffusionGemmaTextExperts`), and community W4A16/AWQ checkpoints exist
  (`pixelkaiser/…AWQ-MLP-W4A16`, `cyankiwi/…AWQ-INT4`, ~13GB).
- **Serving 4-bit for this diffusion arch in vLLM is NOT supported.** vLLM's diffusion Model Runner V2
  wires only **FP8 and NVFP4** into the denoising/bidirectional-attention path; the AWQ/GPTQ/Marlin
  int4 kernels (which work fine for causal LLMs on Ada SM 8.9) are not exposed to it.

Two independent corroborations: (a) agy's kernel analysis; (b) RedHat shipped only FP8+NVFP4 despite
owning the tooling to make W4A16. Both parties stopped at FP8/NVFP4 → strong signal.

## NVFP4 is the only 4-bit vLLM path — and it needs Blackwell. Ada is out.
So on Ada, the vLLM-servable options are effectively **FP8 (14k ceiling)** only.

## The one unresolved empirical question
Both findings are NEGATIVE claims. W4A16 checkpoints physically exist. The definitive test is cheap:
download `pixelkaiser/diffusiongemma-26B-A4B-it-AWQ-MLP-W4A16-G64-S32-L1024` (~13GB) and attempt
`vllm serve`. Loads+runs → 100k ctx unlocked (agy wrong). Kernel error → ceiling confirmed with evidence.
**Recommend running this before accepting the ceiling.**

## Decision tree
1. **Run the W4A16 serve test.**
   - PASS → new provider entry at ~100k ctx; likely retire the mux (co-resides w/ Ollama). Best case.
   - FAIL → go to 2.
2. **Accept FP8@14k** as the ceiling on Ada. DiffusionGemma stays an EXPERIMENTAL provider good for
   evaluating decode quality / tool-calling on short tasks, NOT a daily agentic driver. Revisit when
   vLLM merges int4 kernels for the diffusion runner (track upstream).
3. Non-options: self-quant W4A16 (same serving wall); llama.cpp GGUF (no OpenAI /v1 → can't join the
   Pi provider seam).

## If we want a real agentic diffusion model later, the levers are:
- vLLM upstream adds AWQ/GPTQ int4 support to the DiffusionGemma runner (watch the repo), OR
- a Blackwell GPU (NVFP4 path opens), OR
- stay on the Ollama tier for agentic coding and use DiffusionGemma only for short specialized calls.
