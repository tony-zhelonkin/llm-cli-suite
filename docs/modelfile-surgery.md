# Ollama — Modelfile Surgery: Baking `num_ctx` and Samplers into a Model

> **What this is**: the per-model layer of tuning. This is the part I had *forgotten I did* — I
> thought I only changed the KV cache centrally. I did not: every agentic model on this box
> carries a hand-edited Modelfile with a 128k context window and tuned samplers baked in. The
> exports live in `modelfiles/`.

---

## Why this exists

Ollama defaults a model's context window to something small (4k). The global systemd override
([[ollama-tuning]]) changes *how* the cache is stored, but not *how big* it is — that ceiling is
per-model, and it lives in the Modelfile. If a model reports a tiny context to the Pi agent or
goes stupid past ~30k tokens, its Modelfile is missing `num_ctx`.

So for each agentic model I ran the export → edit → create loop and baked in `num_ctx 131072`
(128k), plus a few sampler parameters.

---

## The surgery loop

```bash
# 1. Inspect what the model currently carries
ollama show qwen3.6:35b --modelfile

# 2. Export it to a file
ollama show qwen3.6:35b --modelfile > my_model.mf

# 3. Append / edit the parameters (128k = 131072)
echo "PARAMETER num_ctx 131072" >> my_model.mf

# 4. Recreate — near-instant, it reuses the existing blobs
ollama create qwen3.6:35b -f my_model.mf

# 5. Clean up
rm my_model.mf
```

The shipped `modelfiles/*.mf` in this repo are the live exports, so the recreate step can read
straight from them (`ollama create <name> -f modelfiles/<name>.mf`).

---

## What is actually baked in (the live state)

Every agentic model carries `num_ctx 131072`. The samplers differ per model family:

| Model | `num_ctx` | Notable samplers |
| :--- | :--- | :--- |
| `qwen3.6:35b` | 131072 | `temperature 1`, `top_k 20`, `top_p 0.95`, `presence_penalty 1.5`, `repeat_penalty 1` |
| `qwen3.6:35b-a3b` | 131072 | (defaults) |
| `qwen3-coder:30b` | 131072 | `temperature 0.7`, `top_k 20`, `top_p 0.8`, `repeat_penalty 1.05`, `stop <\|im_start\|>` / `<\|im_end\|>` / `<\|endoftext\|>` |
| `gemma4:31b` | 131072 | `temperature 1`, `top_k 64`, `top_p 0.95` |
| `gemma4:26b` | (default) | `temperature 1`, `top_k 64`, `top_p 0.95` |
| `batiai/qwen3.6-27b:iq4` | 131072 | `temperature 0.7`, `top_k 20`, `top_p 0.95`, `stop` tokens |

What the knobs buy me:

- **`num_ctx 131072`** — the agent can hold a large project in context. This is the load-bearing
  one for agentic coding. It also sets the KV-cache VRAM budget (mitigated by `q8_0`).
- **`temperature`** — 0.7 for the code models (deterministic, strict), 1.0 for the general/
  multimodal ones (a little more range).
- **`repeat_penalty ~1.05`** — keeps small MoE models from looping.
- **`stop` tokens** — the Qwen chat template boundaries, so generation halts cleanly.

---

## This is only half the wiring

Baking `num_ctx` into the Modelfile sets the *model's* ceiling. The **Pi agent still has to be
told** the window in its `models.json` (`config/models.agentic.json`), or it will request its own
default. Both must agree. After editing a Modelfile:

1. Update the model list in `config/models.agentic.json`.
2. Propagate with `llm-sync`.
3. In the devcontainer, re-run `.devcontainer/scripts/setup_pi.sh`.

---

## TL;DR

- Context-window size is **per-model**, baked via Modelfile surgery — not a global setting.
- Yes, I did touch Modelfiles: every agentic model has `num_ctx 131072` + tuned samplers.
- Export → append `PARAMETER` → `ollama create` (reuses blobs, near-instant).
- The agent's `models.json` must carry the same `contextWindow`, or the two disagree.
