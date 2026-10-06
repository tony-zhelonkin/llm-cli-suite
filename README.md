# Local LLM Workstation Toolkit

A small set of CLI tools and version-controlled config for running local LLMs on a single
high-memory Linux workstation
* managing what sits on the GPU, 
* serving models to a coding agent,
* and keeping the box from falling over. 

It grew out of my own trial and error on one machine. I tried to write the
docs so someone with their own hardware can follow the same path.

## The hardware it grew on

- **Workstation:** Dell Precision 7960 Tower
- **CPU:** Intel Xeon w9-3475X (36c/72t)
- **RAM:** 512GB DDR5-4800 ECC
- **GPU:** NVIDIA RTX 5000 Ada — 32GB, compute capability 8.9 (Ada Lovelace)
- **Storage:** 1TB NVMe (OS/scratch) + 2×8TB SATA (model storage)

The single 32GB GPU is the main constraint. 
Almost every decision here comes back to *what fits in 32GB, and what to do when it doesn't.*

## Where this started, and where it landed

I began by trying to run the biggest thing I could — `qwen3-coder:480b`. 

It technically "ran," but the weights spilled out of VRAM into system RAM, so it paged off the 
SATA disks: 20–30 minute cold starts and single-digit tokens/sec. 

Clamping its context to survive killed the only reason to want a model that large. 
The lesson stuck: **on one 32GB card, a well-quantized 27–35B model that lives
entirely on the GPU beats a giant that spills to RAM.**

So everything grew from there: 
* one model resident on the GPU at a time, 
* quantized to fit, with a 128k window via `q8_0` KV-cache quantization. 

The tools here manage that residency, and the docs go into the general theory and details.

Later I added a second kind of backend — a **diffusion** LLM (Google's DiffusionGemma) served by
vLLM alongside Ollama, reachable by the same coding agent through a clean provider seam. 

Getting it onto a frozen-driver 32GB box was its own adventure; that story is in
[`docs/diffusiongemma-testing.md`](docs/diffusiongemma-testing.md) and the research trail under
`docs/agent-research/`.

## The tools

| Tool | Side | What it does |
|---|---|---|
| `llm-manage` | server | Load/flush an Ollama model on the GPU, injecting a strict context window at load time so KV cache can't run away. Single-model residency by design. |
| `llm-status` | server | One-screen dashboard: system RAM, VRAM (or unified memory on a Mac), and which model is hot. |
| `gpu-switch` | server · **Linux/NVIDIA only** | Hand the single GPU between Ollama and the vLLM diffusion server — stop one, wait for VRAM to actually drain, start the other. They can't co-reside on 32GB. |
| `sys-ram-watchdog` | server | Background daemon that alerts at 90% / 99% RAM/VRAM (systemd user unit; launchd agent on a Mac). |
| `sys-notify` | server | Push-notification sender (reads `~/.config/pushover.env`). |
| `llm-agent-config` | client | Render the agent's `models.json` for wherever this shell is — Linux host, Mac, container. |
| `llm-sync` | client | Find `.devcontainer` folders across the workspace and inject the current model config, so a containerised agent talks to the host models. |

The diffusion vLLM unit (`systemd/diffusiongemma.service`) is Linux/NVIDIA only too. The server
half runs on the box with the accelerator, the client half wherever an agent runs; the split is
drawn in [`docs/architecture.md`](docs/architecture.md).

## Serving models to a coding agent

Model lists live in `config/providers/*.json` — one file per backend. 

A renderer (`config/master_setup_pi.sh`) merges them into the agent's config and rewrites each backend's host
per environment: `localhost` in a host shell, the Docker bridge in a Linux devcontainer,
`host.docker.internal` in a Docker Desktop container on a Mac. 

Adding a new backend — Ollama, a vLLM endpoint, anything OpenAI-compatible 
is just a new JSON file, no code change. 

See [`docs/architecture.md`](docs/architecture.md).

## Install

```bash
./install.sh          # symlinks the tools into ~/.local/bin, enables the watchdog
llm-agent-config      # renders ~/.pi/agent/models.json for this shell
```

`install.sh` works out the OS, installs only what's valid there, and tells you what it skipped.
It's safe to re-run.

Create `~/.config/pushover.env` with your keys if you want notifications.

## On macOS

It runs on a Mac too (Apple Silicon, Ollama.app or `brew install ollama`, stock bash 3.2). Not
everything comes along:

- **Works:** `llm-manage`, `llm-status`, `sys-ram-watchdog` (as a launchd agent), `sys-notify`,
  `llm-agent-config`, `llm-sync`.
- **Doesn't, by design:** `gpu-switch` and the diffusion vLLM server. They manage NVIDIA VRAM and a
  CUDA build; on a Mac they refuse with one line, and `install.sh` skips them.
- **Different:** memory is unified, so there's no VRAM line, only the RAM the GPU shares. The budget
  is whatever's left after macOS and your apps, not a 32GB card. The Ollama tuning goes in through
  `launchctl` rather than a systemd override; see [`launchd/README.md`](launchd/README.md).

The Mac path is in [`docs/getting-started.md`](docs/getting-started.md#on-a-mac).

## Getting started

[`docs/getting-started.md`](docs/getting-started.md) walks the whole path step by step — install and
tune Ollama, pull and bake a model, load it, then (optionally) stand up the DiffusionGemma server —
so you can follow in my footsteps.

## Make it yours

A few things are specific to my box and you'll want to change them: the workspace roots in
`bin/llm-sync` (or set `LLM_SYNC_ROOTS`), the model aliases in `bin/llm-manage`, the `OLLAMA_MODELS` path in the Ollama
override, the model IDs in `config/providers/*.json`, and the `User=`/venv path in the diffusion
unit. The `+cu129` vLLM pin is tied to my frozen driver — a modern driver can use stock vLLM. The
full table of what to tweak is at the end of [`docs/getting-started.md`](docs/getting-started.md#make-it-yours).

## Tests

```bash
make test      # offline suite — the renderer, config, install-from-scratch, syntax (what CI runs)
make verify    # on-box: confirm the running system matches the repo (no local drift)
```

CI runs `make test` on every push; a golden fixture locks the renderer's output so what's on GitHub
can't drift from tested behaviour. See [`tests/README.md`](tests/README.md).

## Docs

**Field notes (the story):**
- [`docs/story-why-not-480b.md`](docs/story-why-not-480b.md) — the 480B experiment and fitting the GPU instead.
- [`docs/story-serving-a-diffusion-llm.md`](docs/story-serving-a-diffusion-llm.md) — getting DiffusionGemma onto a frozen-driver 32GB box.

**Reference:**
- [`docs/memory_physics.md`](docs/memory_physics.md) — KV cache, the `mmap` spill trap, why 480B OOM'd.
- [`docs/ollama-tuning.md`](docs/ollama-tuning.md) — global tuning: KV quantization, flash attention.
- [`docs/modelfile-surgery.md`](docs/modelfile-surgery.md) — baking context and samplers per model.
- [`docs/devcontainer-ollama-passthrough.md`](docs/devcontainer-ollama-passthrough.md) — agent-in-container → host GPU models (Ollama + diffusion): addressing, firewall, GPU mutex.
- [`docs/diffusiongemma-testing.md`](docs/diffusiongemma-testing.md) — serving a diffusion LLM as a second provider.
- [`docs/architecture.md`](docs/architecture.md) — the server/client split, the tools, the provider seam, and where each environment's host comes from.
</content>
