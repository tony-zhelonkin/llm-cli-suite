# Brief — vLLM ↔ CUDA-12.x ↔ DiffusionGemma compatibility (for a driver-565 box)

CLI/model: agy (Gemini 3.1 Pro High), web search on. Report: report_1_vllm-cuda12-diffusiongemma.md

## Context
- Host: Ubuntu 22.04, NVIDIA RTX 5000 Ada, driver **565.57.01** → exposes **CUDA 12.7**.
  The driver is DELIBERATELY frozen at 565 (Secure Boot + Intel VMD constraints; 580 is off-limits).
- Goal: serve `nvidia/diffusiongemma-26B-A4B-it-NVFP4` (Google DiffusionGemma, arch
  `DiffusionGemmaForBlockDiffusion`) via vLLM's OpenAI `/v1` server, purely to measure resident VRAM.
- Blocker: `pip install vllm` gave vLLM **0.26.0** bundling **torch 2.11.0+cu130** (CUDA 13.0), which
  requires driver **>=580**. On driver 565 it dies at `torch._C._cuda_init()`:
  "NVIDIA driver too old (found 12070)". CUDA 12->13 is a MAJOR gap, no minor-version shim.

## Questions (answer in markdown, cite sources with URLs + dates)
1. What is the EARLIEST and the NEWEST vLLM release that supports DiffusionGemma
   (`DiffusionGemmaForBlockDiffusion`, "first dLLM natively supported in vLLM", ~2026-06)? Version numbers.
2. For each such vLLM version, which CUDA build does its PyPI wheel ship (cu121/cu124/cu126/cu128/cu130)?
   Is there ANY vLLM release that supports DiffusionGemma AND ships a **CUDA 12.6 or lower** wheel
   (torch cu126/cu124) that would run on an NVIDIA **565** driver (CUDA 12.7)?
3. Does vLLM publish alternate-CUDA wheels (e.g. a cu126 index) for the DiffusionGemma-capable release,
   e.g. via `--extra-index-url https://download.pytorch.org/whl/cu126` or a vLLM-hosted wheel index?
   Exact install command if so.
4. Minimum NVIDIA driver version required by torch cu128 (CUDA 12.8) and cu126 (CUDA 12.6) on Linux —
   confirm whether 565.57.01 satisfies cu126 and/or cu128.
5. Any alternative runtime to serve DiffusionGemma NVFP4 on a CUDA-12.7 / driver-565 box WITHOUT
   upgrading the driver (older vLLM, HF Transformers path, TensorRT-LLM, sglang)? Feasible or not?
6. Bottom line: is there a driver-565-compatible way to run this model today, or is it genuinely
   gated on a >=580 driver? A clear yes/no with the reasoning.
