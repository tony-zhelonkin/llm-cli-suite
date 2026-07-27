# W4A16 empirical test — agy's "blocked" verdict was WRONG (2026-07-26)

**Ran the test agy said would fail. It works.** `pixelkaiser/diffusiongemma-26B-A4B-it-AWQ-MLP-W4A16-G64-S32-L1024`
serves under vLLM 0.26.0+cu129 on the RTX 5000 Ada (SM 8.9), frozen 565 driver.

## The decisive log lines
```
Using MarlinLinearKernel for CompressedTensorsWNA16
Using CompressedTensorsWNA16MarlinMoEMethod
Using 'MARLIN' WNA16 MoE backend                 ← int4 MoE kernel on Ada, in the diffusion runner
Model loading took 14.99 GiB and 13.7 s
Available KV cache memory: 12.94 GiB
GPU KV cache size: 487,479 tokens                 (at --max-model-len 131072, concurrency 3.72x)
Application startup complete
```
Chat smoke at both 65k and 128k returned correct output ("quant works" / "128k works").

## Why agy was wrong
agy claimed the AWQ/GPTQ/Marlin int4 kernels are "not exposed/compatible" with the DiffusionGemma
Model Runner V2. Empirically they ARE: vLLM 0.26 selected `MARLIN WNA16` for both the linear and the
**MoE** layers (the hard part) and ran the diffusion sampler on top. Lesson: verify negative claims —
the community W4A16 checkpoint existed, and one 20-min download settled it against the desk research.

## Numbers vs FP8 (same card, same serve flags)
| | FP8-dynamic | **W4A16 (Marlin)** |
|---|---|---|
| Weights resident | ~26 GB | **~15 GB** |
| KV cache | 2.0 GB / 14.6k tok | **12.94 GB / 487k tok** |
| Max context served | 14k (Pi autocompacts ~10k) | **131,072 (128k)** ✅ |
| Resident @ util 0.90 | 30.9 GB | 31.0 GB |
| Verdict | poke-only | **real agentic driver** |

## Serve command (now the systemd default)
```bash
VLLM_USE_V2_MODEL_RUNNER=1 PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  vllm serve pixelkaiser/diffusiongemma-26B-A4B-it-AWQ-MLP-W4A16-G64-S32-L1024 \
  --host 0.0.0.0 --port 11435 --trust-remote-code \
  --max-num-seqs 1 --max-model-len 131072 --gpu-memory-utilization 0.90 \
  --enforce-eager --enable-chunked-prefill \
  --hf-overrides '{"diffusion_sampler":"entropy_bound","diffusion_entropy_bound":0.1}' \
  --diffusion-config '{"canvas_length":256}' \
  --enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4
```

## Open follow-ups
- **Co-residency with Ollama?** Weights are only ~15GB. Capping diffusion KV (e.g. `--kv-cache-memory`
  or lower util + smaller max-model-len) could leave room for a 15GB Ollama 27B on the 32GB card →
  would retire `gpu-switch`. UNTESTED — mux stays for now.
- **Quality vs FP8/base:** W4A16 recovers less than FP8 (near-lossless). Benchmark before trusting for
  hard tasks; fine to start with feel under Pi.
