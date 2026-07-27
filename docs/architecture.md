# Architecture — the tools and the provider seam

A set of small, single-purpose CLI tools plus a config layer that feeds local models to a coding
agent.

Each piece does one thing, and the config is the source of truth. That's the whole idea.

## The tools

Each lives in `bin/`, symlinked into `~/.local/bin` by `install.sh`.

- **`llm-manage`** — load or flush one Ollama model on the GPU. It injects a strict context window
  at load time so KV cache can't grow past the VRAM budget, and watches `VmRSS` to confirm the model
  is physically resident before reporting done. Single-model residency by design.
- **`llm-status`** — one screen: system RAM (`free`), VRAM (`nvidia-smi`), and which model is hot
  (`ollama ps`). The first thing I run to check whether anything has spilled into RAM.
- **`gpu-switch`** — hands the single GPU between Ollama and the vLLM diffusion server. Stops one,
  waits for VRAM to actually drain, starts the other, and polls until it's really serving. They
  can't co-reside on 32GB, so this is the mutex.
- **`llm-sync`** — finds `.devcontainer` folders across the workspace and copies the current model
  config in, so a containerised agent talks to the host models. Docker can't follow symlinks out of
  the build context, so the config is propagated as real files, not links.
- **`sys-ram-watchdog`** — background daemon, alerts at 90% and 99% RAM/VRAM with hysteresis (only
  resets below 85%) so it doesn't spam.
- **`sys-notify`** — push notifications, reads keys from `~/.config/pushover.env`. Nothing else
  knows about the secret.

## The provider seam

The agent reads one `models.json`. 

I don't write it by hand — it's rendered from `config/providers/*.json`, one file per backend.

`config/master_setup_pi.sh` merges those files and rewrites each backend's host for the environment
it's rendering into (host shell vs. the Docker bridge). Each provider file declares its own host
env var and default, so the renderer never special-cases a backend by name.

Adding a backend — Ollama, a vLLM endpoint, anything OpenAI-compatible — is a new JSON file. No code
changes. That's the whole design: the renderer is generic, the provider files are data.

```
config/providers/ollama.agentic.json  ─┐
config/providers/diffusion.json        ─┼─►  master_setup_pi.sh  ─►  ~/.pi/agent/models.json
(one file per backend, declares host)  ─┘    (merge + host rewrite)   (what the agent reads)
```

## Why it's shaped this way

- **One responsibility per tool.** Secrets, notifications, model loading, and monitoring don't
  bleed into each other.
- **Config is data, code is generic.** New models and new backends are edits to JSON, not to scripts.
- **VmRSS, not guesswork.** Residency is measured from `/proc`, so "loaded" means the weights are
  physically in memory, Ollama accepting the load isn't enough.
- **Hysteresis in monitoring.** Warm and cool thresholds (90% / 85%) stop the watchdog flapping.

## Quickstart

```bash
llm-status                       # what's resident right now
llm-manage load qwen3.6-dense    # load a model with its pinned context
llm-manage flush                 # clear the GPU
gpu-switch diffusion             # switch the card to the diffusion server
llm-sync                         # push config to devcontainers after editing providers/
```
