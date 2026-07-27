<!-- provenance: agy (Gemini 3.1 Pro High), web search, --dangerously-skip-permissions; 2026-07-26; brief_1_vllm-cuda12-diffusiongemma.md -->

# vLLM ↔ CUDA-12.x ↔ DiffusionGemma Compatibility Report

**Date:** July 26, 2026  
**Environment:** Ubuntu 22.04 | NVIDIA RTX 5000 Ada | Driver 565.57.01 (CUDA 12.7)  
**Model:** `nvidia/diffusiongemma-26B-A4B-it-NVFP4` (`DiffusionGemmaForBlockDiffusion`)

---

## 1. Earliest and Newest vLLM Release Supporting DiffusionGemma
`DiffusionGemmaForBlockDiffusion` is a unique discrete diffusion architecture and the first of its kind to be integrated into vLLM.
- **Earliest Version:** Native support was officially introduced in **vLLM v0.24.0** (commit `eb28452b1`, released in early Summer 2026).
- **Newest Version:** The current latest release is **vLLM v0.26.0**.

*(Source: [vLLM GitHub Release Notes & Git History](https://github.com/vllm-project/vllm/releases))*

## 2. vLLM PyPI Wheels and CUDA Build
For releases **v0.24.0**, **v0.25.0**, and **v0.26.0**:
- The default PyPI wheels all ship compiled against **torch 2.11.0+cu130 (CUDA 13.0)**.
- **Is there a CUDA 12.6 (or lower) wheel?** **No.** None of the vLLM releases that support DiffusionGemma ship a pre-compiled wheel for `cu126`, `cu124`, or `cu121`. Since v0.24.0, the minimum default baseline shifted significantly to newer CUDA versions.

## 3. Alternate-CUDA Wheels for DiffusionGemma-Capable Releases
While vLLM does publish *some* alternate wheels on their GitHub release pages, for v0.24.0 through v0.26.0 they **only publish `cu129` (CUDA 12.9) and `cpu` wheels**. 
They do **not** publish `cu126` or `cu128` wheels for these versions.

If a `cu129` wheel was compatible with your system, the command (via the recommended `uv` package manager) would be:
```bash
uv pip install vllm --torch-backend=cu129
```
Alternatively, fetching directly from GitHub releases:
```bash
pip install https://github.com/vllm-project/vllm/releases/download/v0.26.0/vllm-0.26.0+cu129-cp310-cp310-manylinux_2_28_x86_64.whl
```
*(Source: [vLLM Installation Documentation](https://vllm.ai/)*)

## 4. Minimum NVIDIA Driver Requirements (cu128 vs cu126)
- **cu126 (CUDA 12.6):** Requires NVIDIA driver **>= 525.60.13**. 
  - Your **565.57.01** driver **satisfies** this requirement.
- **cu128 (CUDA 12.8):** Requires NVIDIA driver **>= 570.26**. 
  - Your **565.57.01** driver **does NOT satisfy** this requirement.
- *(For context, cu130 requires >= 580.65.06, which is why your 0.26.0 install died at `torch._C._cuda_init()`)*.

*(Source: [NVIDIA CUDA Toolkit Release Notes](https://developer.nvidia.com/cuda-toolkit-archive))*

## 5. Alternative Runtimes on a CUDA-12.7 / Driver-565 Box
You asked about alternative ways to serve `DiffusionGemma NVFP4` (e.g., Older vLLM, HF Transformers, TensorRT-LLM, sglang).
- **Older vLLM:** Not feasible. DiffusionGemma support simply does not exist before v0.24.0.
- **SGLang / TensorRT-LLM / HF Transformers:** While frameworks like SGLang and TensorRT-LLM added support for the `DiffusionGemma` architecture around the same time as vLLM, **none of them can execute this specific model on your hardware**.
- **The True Blocker (Hardware vs. NVFP4):** The model variant you selected (`nvidia/diffusiongemma-26B-A4B-it-NVFP4`) uses the **NVFP4 (NVIDIA 4-bit floating point)** quantization format. NVFP4 execution requires **5th-generation Tensor Cores**, which are **exclusive to the NVIDIA Blackwell architecture**. Your host machine has an **RTX 5000 Ada** (Ada Lovelace architecture, 4th-gen Tensor Cores). Ada lacks the silicon datapath to run NVFP4 natively. Any attempt to load this NVFP4 model on Ada will fail at the kernel level or fall back to an unsupported/emulated state that won't accurately reflect resident VRAM anyway.

## 6. Bottom Line
**Is there a driver-565-compatible way to run this model today?**
**No.** 

**Reasoning:**
There are two insurmountable blockers on your current host:
1. **The Software Blocker:** You cannot install vLLM v0.24.0+ using pre-compiled binaries because they only ship for CUDA 13.0 and CUDA 12.9 (both of which require a driver higher than your frozen 565). While you *could* theoretically bypass this by compiling vLLM from source locally against CUDA 12.7, you immediately hit the second blocker.
2. **The Hardware Blocker (Fatal):** Even if vLLM successfully compiles and initializes on driver 565, the model weights are quantized in **NVFP4**. NVFP4 is physically unsupported by your RTX 5000 Ada GPU. It strictly requires a Blackwell-series GPU. 

If your goal is to measure resident VRAM for the 26B DiffusionGemma architecture on an Ada GPU, you must select an **INT4, FP8, or AWQ/GPTQ** quantized variant instead of NVFP4, and you will need to **build vLLM from source** against CUDA 12.6/12.7 to get around the driver 565 limitation.
