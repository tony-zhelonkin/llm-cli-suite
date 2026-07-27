# Local LLM Workstation Toolkit

A small set of CLI tools and version-controlled config for running local LLMs on a single
high-memory Linux workstation — managing what sits on the GPU, serving models to a coding agent,
and keeping the box from falling over. It grew out of my own trial and error on one machine; the
docs are written so someone with their own hardware can follow the same path.

## The hardware it grew on

- **Workstation:** Dell Precision 7960 Tower
- **CPU:** Intel Xeon w9-3475X (36c/72t)
- **RAM:** 512GB DDR5-4800 ECC
- **GPU:** NVIDIA RTX 5000 Ada — 32GB, compute capability 8.9 (Ada Lovelace)
- **Storage:** 1TB NVMe (OS/scratch) + 2×8TB SATA (model storage)

The single 32GB GPU is the whole constraint. Almost every decision here comes back to *what fits
in 32GB, and what to do when it doesn't.*

## Where this started, and where it landed

I began by trying to run the biggest thing I could — `qwen3-coder:480b`. It technically "ran," but
the weights spilled out of VRAM into system RAM, so it paged off the SATA disks: 20–30 minute cold
starts and single-digit tokens/sec. Clamping its context to survive killed the only reason to want
a model that large. The lesson stuck: **on one 32GB card, a well-quantized 27–35B model that lives
entirely on the GPU beats a giant that spills to RAM, every time.**

That became the posture: one model resident on the GPU at a time, quantized to fit, with a real
128k window via `q8_0` KV-cache quantization. The tools here manage that residency, and the docs
work out the memory math behind it.

Later I added a second kind of backend — a **diffusion** LLM (Google's DiffusionGemma) served by
vLLM alongside Ollama, reachable by the same coding agent through a clean provider seam. Getting it
onto a frozen-driver 32GB box was its own adventure; that story is in
[`docs/diffusiongemma-testing.md`](docs/diffusiongemma-testing.md) and the research trail under
`docs/agent-research/`.

## The tools

| Tool | What it does |
|---|---|
| `llm-manage` | Load/flush an Ollama model on the GPU, injecting a strict context window at load time so KV cache can't run away. Single-model residency by design. |
| `llm-status` | One-screen dashboard: system RAM, VRAM, and which model is hot (`free` + `nvidia-smi` + `ollama ps`). |
| `gpu-switch` | Hand the single GPU between Ollama and the vLLM diffusion server — stop one, wait for VRAM to actually drain, start the other. They can't co-reside on 32GB. |
| `llm-sync` | Find `.devcontainer` folders across the workspace and inject the current model config, so a containerised agent talks to the host models. |
| `sys-ram-watchdog` | Background daemon that alerts at 90% / 99% RAM/VRAM. |
| `sys-notify` | Push-notification sender (reads `~/.config/pushover.env`). |

## Serving models to a coding agent

Model lists live in `config/providers/*.json` — one file per backend. A renderer
(`config/master_setup_pi.sh`) merges them into the agent's config and rewrites each backend's host
per environment (host shell vs. devcontainer bridge). Adding a new backend — Ollama, a vLLM
endpoint, anything OpenAI-compatible — is a new JSON file, no code change. See
[`docs/architecture.md`](docs/architecture.md).

## Install

```bash
./install.sh          # symlinks the tools into ~/.local/bin, enables the watchdog
```

Create `~/.config/pushover.env` with your keys if you want notifications.

## Docs

**Field notes (the story):**
- [`docs/story-why-not-480b.md`](docs/story-why-not-480b.md) — the 480B experiment and fitting the GPU instead.
- [`docs/story-serving-a-diffusion-llm.md`](docs/story-serving-a-diffusion-llm.md) — getting DiffusionGemma onto a frozen-driver 32GB box.

**Reference:**
- [`docs/memory_physics.md`](docs/memory_physics.md) — KV cache, the `mmap` spill trap, why 480B OOM'd.
- [`docs/ollama-tuning.md`](docs/ollama-tuning.md) — global tuning: KV quantization, flash attention.
- [`docs/modelfile-surgery.md`](docs/modelfile-surgery.md) — baking context and samplers per model.
- [`docs/devcontainer-ollama-passthrough.md`](docs/devcontainer-ollama-passthrough.md) — agent-in-container → host models.
- [`docs/diffusiongemma-testing.md`](docs/diffusiongemma-testing.md) — serving a diffusion LLM as a second provider.
- [`docs/architecture.md`](docs/architecture.md) — the tools and the provider seam.
</content>
