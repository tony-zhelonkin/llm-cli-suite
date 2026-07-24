# Modelfiles — per-model tuning exports

These are the **live Ollama Modelfile exports** for the agentic model list on the workstation,
captured with `ollama show <model> --modelfile`. They are the per-model tuning layer: baked
context window (`num_ctx 131072`) and sampler parameters. See
[`../docs/modelfile-surgery.md`](../docs/modelfile-surgery.md) for the full story and the
export → edit → create loop.

## What lives here

| File | Model | Notes |
| :--- | :--- | :--- |
| `batiai_qwen3.6-27b_iq4.mf` | `batiai/qwen3.6-27b:iq4` | Primary agent (dense, IQ4 quant), 128k |
| `qwen3-coder_30b.mf` | `qwen3-coder:30b` | Specialised code, 128k, Qwen stop tokens |
| `qwen3.6_35b.mf` | `qwen3.6:35b` | Fast MoE agent, 128k |
| `qwen3.6_35b-a3b.mf` | `qwen3.6:35b-a3b` | Super-fast A3B variant, 128k |
| `gemma4_31b.mf` | `gemma4:31b` | Multimodal / docs, 128k |
| `gemma4_26b.mf` | `gemma4:26b` | Older multimodal variant |

## How to restore a model's tuning from here

```bash
ollama create qwen3.6:35b -f qwen3.6_35b.mf   # near-instant, reuses existing blobs
```

## Layer relationship

- **These files** = per-model context size + samplers.
- **`../systemd/ollama.override.conf`** = global KV-cache quantization + flash attention.

Two independent layers — do not confuse them. See
[`../docs/ollama-tuning.md`](../docs/ollama-tuning.md).

> Note: model quantization itself (`:iq4`, `:q4_K_M`, etc.) is chosen at pull time via the Ollama
> tag, not in these Modelfiles. These only carry runtime parameters.
