# Reference — RedHatAI FP8 model card (primary source) + what it means for a self-quant

Source: HF model card for `RedHatAI/diffusiongemma-26B-A4B-it-FP8-dynamic` (provided by Anton 2026-07-26).

## The unlock: llm-compressor already supports DiffusionGemma
RedHat's `Creation` script uses **LLM Compressor v0.11.0** with a purpose-built modeling helper:
```python
from llmcompressor.modeling.diffusion_gemma4 import CalibrationDiffusionGemmaTextExperts
```
This class (used during calibration) does the two hard MoE things:
1. **Linearizes the 3D expert tensors** into individual `nn.Linear` modules so the quantizer can see them.
2. **Calibrates ALL experts**, including ones not activated for the calibration tokens.

So the MoE+diffusion arch — the thing we feared would break AutoAWQ/AutoGPTQ — is **explicitly handled
by llm-compressor**. Param split (from the card): total ~25.8B, experts 22.8B (88.4%), non-expert 3.0B.

## The recipe is a one-line scheme swap away from INT4
RedHat's FP8 recipe:
```python
QuantizationModifier(
    targets="Linear", scheme="FP8_DYNAMIC",
    ignore=["lm_head","re:.*embed.*","re:.*router","re:.*vision_tower.*","re:.*self_conditioning.*"],
)
```
→ To make our ~13GB Ada-servable build, swap `scheme="FP8_DYNAMIC"` for a **4-bit weight scheme**
(`W4A16` via GPTQModifier / compressed-tensors), keeping the SAME ignore list + the same
`CalibrationDiffusionGemmaTextExperts` support. W4A16 = 4-bit weights, 16-bit activations →
25.8B × ~0.5B ≈ **~13GB weights** → ~15GB+ free for KV on the 32GB card → target ~100k ctx.

## FP8 accuracy recovery (their benchmarks, B200) — sets the bar for how much W4A16 may cost
| Benchmark | base | FP8 | recovery |
|---|---|---|---|
| AIME 2025 | .437 | .423 | 96.8% |
| GPQA Diamond | .641 | .657 | 102.5% |
| IFEval | .879 | .862 | 98.1% |
| GSM8K | .943 | .942 | 99.9% |
| MMLU 0-shot | .539 | .505 | 93.7% |
(FP8 is near-lossless; W4A16 will recover less — must be re-benchmarked, but the tooling is the same.)

## Their deployment differs from ours (they're on a B200, 180GB)
```
--max-num-seqs 4   --default-chat-template-kwargs '{"enable_thinking": true}'
```
No `--enforce-eager`, no low `--gpu-memory-utilization` — because a B200 isn't VRAM-constrained.
On our 32GB Ada we keep the tight config; note their `enable_thinking` chat kwarg (we should add it).

## What still must be confirmed (agy report Q1-Q6 in flight)
1. Does a **ready-made W4A16/AWQ/GPTQ** DiffusionGemma already exist on HF? (If yes, skip self-quant.)
2. Does the `llmcompressor.modeling.diffusion_gemma4` module ship in a **pip-installable** llm-compressor
   release, or is it a RedHat local patch? (The "local update to transformers" note hints at patches.)
3. Does **vLLM 0.26 load a W4A16 compressed-tensors DiffusionGemma AND run int4 (Marlin) kernels on
   Ada SM 8.9**? (Marlin generally runs Ampere+, so likely yes — confirm.)
4. Self-quant cost: FP16 base is ~52GB (> 32GB card) → needs **CPU offload** during `oneshot`
   (`dispatch_model` in their script); we have 502GB RAM, so feasible but slow. Calibration dataset?

## Bottom line so far
The blocker was never "can the arch be 4-bit quantized" — RedHat proved the tooling exists. The
remaining question is only **ready-made vs. self-quant**, and whether vLLM serves the result on Ada.
