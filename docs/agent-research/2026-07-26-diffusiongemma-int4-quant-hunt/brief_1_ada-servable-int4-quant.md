# Brief — find an Ada-servable low-bit DiffusionGemma quant (bigger context)

CLI/model: agy (Gemini 3.1 Pro High), web search on. Report: report_1_ada-servable-int4-quant.md

## Context (hard constraints — all verified on the box)
- GPU: **NVIDIA RTX 5000 Ada** (Ada Lovelace, compute capability **SM 8.9**), **32 GB**.
- Driver **565.57.01** frozen → working stack is **vLLM 0.26.0 + torch 2.11 `+cu129`** (CUDA 12.9
  runs on the 12.7 driver via minor-version compat). Any quant MUST be servable by this vLLM.
- Model: Google **DiffusionGemma 26B-A4B** (MoE, arch `DiffusionGemmaForBlockDiffusion`; the "first
  dLLM natively supported in vLLM"). Served with `--enable-auto-tool-choice --tool-call-parser
  gemma4 --reasoning-parser gemma4`, `--hf-overrides`/`--diffusion-config`, `--max-num-seqs 1`.
- MEASURED so far: **FP8** (RedHatAI/diffusiongemma-26B-A4B-it-FP8-dynamic) = **~26 GB weights**,
  leaves only ~2 GB KV → **~14k ctx max**. Too small: Pi (coding agent) autocompacts ~10k.
- RULED OUT: **NVFP4** (`nvidia/...-NVFP4`) — needs Blackwell 5th-gen tensor cores; **Ada cannot run
  it**. Do NOT propose NVFP4 or any FP4 that requires Blackwell.
- GOAL: a **~4-bit / ~13 GB weight** quant → frees ~15+ GB for KV → **~100k ctx**, and possibly
  co-residency with a 15-23 GB Ollama model on the 32 GB card.

## Questions (answer in markdown; cite HF repo URLs + dates; be concrete)
1. Which **INT4 / W4A16 / AWQ / GPTQ / compressed-tensors** quantizations of DiffusionGemma-26B-A4B
   exist on Hugging Face TODAY? List exact repo ids + approx weight size on disk.
2. For each: can **vLLM 0.26** load it (quant method supported by vLLM's DiffusionGemma path), and
   does the kernel run on **Ada SM 8.9** (NOT Blackwell-only)? AWQ/GPTQ/Marlin int4 on Ada — supported?
3. **GGUF caveat:** `unsloth/diffusiongemma-26B-A4B-it-GGUF` exists — but can vLLM serve GGUF for THIS
   diffusion arch, or is it llama.cpp-only (needs `llama-diffusion-cli`, no OpenAI /v1)? Confirm.
4. If NO ready 4-bit vLLM-servable quant exists: is it feasible to **quantize FP16→INT4 ourselves**
   for this MoE diffusion arch with llm-compressor / AutoAWQ / AutoGPTQ, and are there known
   blockers (MoE + diffusion block-decoding incompatibility with these quantizers)?
5. Realistic **weights-GB and max-context** estimate for the best Ada-servable 4-bit option on 32 GB.
6. Bottom line: name the **single best path** to a >=64k-context DiffusionGemma on this Ada box, or
   state plainly if FP8@14k is currently the ceiling until a 4-bit vLLM-servable quant ships.
