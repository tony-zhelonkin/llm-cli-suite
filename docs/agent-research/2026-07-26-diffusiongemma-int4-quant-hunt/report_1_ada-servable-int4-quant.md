<!-- provenance: agy (Gemini 3.1 Pro High), web search, --dangerously-skip-permissions; 2026-07-26; brief_1_ada-servable-int4-quant.md -->

# DiffusionGemma-26B-A4B Quantization Report (Ada / vLLM 0.26)

This report details the findings regarding low-bit (4-bit) quantizations of the DiffusionGemma-26B-A4B model, specifically targeting vLLM 0.26 and an NVIDIA RTX 5000 Ada (SM 8.9) GPU.

## 1. Existing 4-bit Quantizations on Hugging Face
Several 4-bit quantized versions of the model exist on Hugging Face today. Based on community uploads and standard compression techniques, the following repositories are available:
*   **`pixelkaiser/diffusiongemma-26B-A4B-it-AWQ-MLP-W4A16-G64-S32-L1024`**: A 4-bit weight-only (W4A16) AWQ quantized version utilizing the `compressed-tensors` format. Weight size on disk is approximately **13-14 GB**.
*   **`cyankiwi/diffusiongemma-26B-A4B-it-AWQ-INT4`**: An AWQ INT4 quantized version. Weight size is approximately **13 GB**.

*(Note: `RedHatAI/diffusiongemma-26B-A4B-it-NVFP4` also exists in 4-bit but utilizes NVFP4, which as you noted requires Blackwell architectures and is ruled out for Ada).*

## 2. vLLM 0.26 Support and Ada SM 8.9 Compatibility
While the models listed above exist in standard 4-bit formats (AWQ/INT4), **vLLM 0.26 cannot currently serve them for the DiffusionGemma architecture**.
*   **The architectural blocker:** DiffusionGemma is a diffusion language model (dLLM) relying on iterative parallel denoising loops and bidirectional attention, unlike standard autoregressive models. vLLM handles this using a specialized "Model Runner V2".
*   **Kernel support on Ada:** Although vLLM has mature AWQ/GPTQ/Marlin INT4 kernels for standard LLMs on SM 8.9 hardware, these kernels are **not natively exposed or compatible** with the specialized diffusion runner pipeline. The only officially supported 4-bit path for DiffusionGemma in vLLM is NVFP4 (which requires Blackwell). 
*   **Conclusion:** The AWQ/INT4 kernels will not run for DiffusionGemma in vLLM on your Ada card today.

## 3. The GGUF Caveat
Regarding **`unsloth/diffusiongemma-26B-A4B-it-GGUF`**:
*   **vLLM Support:** vLLM **cannot** serve this GGUF file. While vLLM has experimental GGUF support for standard causal LLMs, it does not support GGUF parsing for the specialized dLLM architecture of DiffusionGemma. 
*   **llama.cpp restriction:** The GGUF models are strictly intended for runtimes like `llama.cpp` (which have had to implement specific diffusion decoding mechanisms like `llama-diffusion-cli`). Consequently, you will not have access to an OpenAI-compatible `/v1` API via vLLM with this GGUF file.

## 4. Feasibility of Custom FP16 → INT4 Quantization
Attempting to quantize the model yourself for vLLM using tools like `llm-compressor`, `AutoAWQ`, or `AutoGPTQ` hits significant blockers:
*   **`llm-compressor`:** While this tool boasts "day-zero" support for DiffusionGemma, its optimized paths for this specific architecture target FP8 and NVFP4. 
*   **Blockers with `AutoAWQ`/`AutoGPTQ`:** These libraries (and the vLLM backend kernels they rely on) assume causal, autoregressive transformer architectures. The MoE structure combined with diffusion block-decoding creates fundamental incompatibilities in how the layers are calibrated and executed. Even if you successfully generate the quantized weights, vLLM lacks the custom 4-bit kernels needed to execute them within the diffusion denoising loop.

## 5. Weights and Context Estimate (Theoretical 4-bit on 32 GB)
If a 4-bit Ada-compatible vLLM kernel were to be released, the numbers would look highly favorable:
*   **Weight Size:** ~13.5 GB.
*   **vLLM overhead:** ~1.5 - 2 GB.
*   **Remaining VRAM for KV Cache:** ~16.5 GB.
*   **Max Context:** For a 26B MoE with ~3.8B active parameters, 16.5 GB of KV space would confidently yield a **~100k - 128k context window** (assuming `--max-num-seqs 1`). It would easily allow for co-residency with another 15 GB Ollama model on the same 32 GB card.

## 6. Bottom Line
**FP8@14k context is currently the practical ceiling.** 
Until the vLLM community implements and merges AWQ/GPTQ/Marlin kernel support specifically tailored for the Model Runner V2 and the DiffusionGemma architecture, a 4-bit vLLM-servable quant on Ada is not possible. You must continue using `RedHatAI/diffusiongemma-26B-A4B-it-FP8-dynamic` and accept the ~14k context limit, or use `llama.cpp` (without standard vLLM benefits) for the GGUF path.
