# Docs

The docs split two ways: the **story** (field notes, in order) and the **reference** (how the
pieces work). If you're here to follow the journey, read top to bottom.

## The story, in order

1. [`story-why-not-480b.md`](story-why-not-480b.md) — where it began. Trying to run a 480B model on
   one 32GB card, watching it spill to RAM, and the shift to fitting the GPU instead of fighting it.
2. [`story-serving-a-diffusion-llm.md`](story-serving-a-diffusion-llm.md) — adding a second kind of
   backend. Getting Google's DiffusionGemma onto a frozen-driver 32GB box, through the quant maze,
   to a 128k agent.

## Reference

**The model tier (Ollama):**
- [`memory_physics.md`](memory_physics.md) — KV cache, the `mmap` spill trap, why the 480B OOM'd.
  The math behind "fit the GPU."
- [`ollama-tuning.md`](ollama-tuning.md) — global tuning: KV-cache quantization, flash attention,
  where the settings live.
- [`modelfile-surgery.md`](modelfile-surgery.md) — baking context window and samplers into a model.

**Serving to the agent:**
- [`architecture.md`](architecture.md) — the CLI tools and the provider seam that feeds models to Pi.
- [`devcontainer-ollama-passthrough.md`](devcontainer-ollama-passthrough.md) — an agent inside a
  container reaching the host's models over the Docker bridge.
- [`diffusiongemma-testing.md`](diffusiongemma-testing.md) — the runbook for the diffusion provider.

**Deeper trail:**
- `agent-research/` — the research and measurements behind the diffusion work (compat, VRAM, the
  quant hunt).
- `plan/` — the phased rollout plan for the second provider.
- [`CHANGELOG.md`](CHANGELOG.md) — version history.
