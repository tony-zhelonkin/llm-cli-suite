# Architecture — the tools and the provider seam

A set of small, single-purpose CLI tools plus a config layer that feeds local models to a coding
agent.

Each piece does one thing, and the config is the source of truth. That's the whole idea.

## Two halves: the server and the client

The suite splits along one line. The **server** half runs on whichever box has the accelerator and
serves the models. The **client** half runs wherever an agent runs, and only needs to know how to
reach that server.

```
SERVER — one per box with the accelerator           CLIENT — anywhere an agent runs
──────────────────────────────────────────          ─────────────────────────────────
Ollama  :11434   (+ tuning: systemd override        config/providers/*.json   the roster
                  on Linux, launchd on a Mac)              │
vLLM diffusion :11435   ── Linux/NVIDIA only               ▼
                                                    render_pi_models  (master_setup_pi.sh)
llm-manage        load / flush one model                   │   resolves each provider's host
llm-status        RAM, VRAM / unified memory, ollama ps    │   for *this* environment
sys-ram-watchdog  alerts at 90% / 99%                      ▼
sys-notify        Pushover                          ~/.pi/agent/models.json   what Pi reads
gpu-switch        GPU mutex ── Linux/NVIDIA only
                                                    entrypoints:
                                                      llm-agent-config   bare host, Linux or Mac
                                                      setup_pi.sh        in a devcontainer
                                                                         (shipped by llm-sync)
```

On my workstation both halves live on the same box: the server on the GPU, and clients both in the
host shell and in two dozen devcontainers. On a Mac it's the same split, just smaller. Ollama.app is
the server on Metal, the Mac shell is one client and a Docker Desktop container is another. There's
no diffusion server and no `gpu-switch` there. Those manage NVIDIA VRAM and a CUDA vLLM build, so on
a Mac they refuse with one line and `install.sh` doesn't install them.

The layout follows the split: server tools in `bin/` + `systemd/` (Linux) or `launchd/` (macOS),
the client roster in `config/providers/`, the renderer in `config/master_setup_pi.sh`.
`lib/platform.sh` is the small shared bit the server tools source: which OS, which accelerator, how
much memory is used.

## The tools

Each lives in `bin/`, symlinked into `~/.local/bin` by `install.sh` (which only links what's valid
for the OS, and says what it skipped).

**Server side:**

- **`llm-manage`** — load or flush one Ollama model. It injects a strict context window at load
  time so KV cache can't grow past the memory budget. It reports the model hot only when `/api/ps`
  lists it, not when Ollama merely accepts the load, and says how many GB landed on the GPU. Single-model residency by
  design.
- **`llm-status`** — one screen: system RAM, VRAM (`nvidia-smi`) or the unified-memory note on a
  Mac, and which model is hot (`ollama ps`). Totals and the GPU name are read from the box. The
  first thing I run to check whether anything has spilled into RAM.
- **`gpu-switch`** *(Linux/NVIDIA only)* — hands the single GPU between Ollama and the vLLM
  diffusion server. Stops one, waits for VRAM to actually drain, starts the other, and polls until
  it's really serving. They can't co-reside on 32GB, so this is the mutex.
- **`sys-ram-watchdog`** — background daemon (systemd user unit on Linux, launchd agent on a Mac),
  alerts at 90% and 99% RAM/VRAM with hysteresis (only resets below 85%) so it doesn't spam. VRAM is
  only watched where `nvidia-smi` exists; on a Mac, RAM *is* the GPU's memory.
- **`sys-notify`** — push notifications, reads keys from `~/.config/pushover.env`. Nothing else
  knows about the secret.

**Client side:**

- **`llm-agent-config`** — renders `~/.pi/agent/models.json` for the shell it runs in. It's the
  thin entrypoint for a host or a Mac: no npm, no Pi install, just the roster → the agent's config.
  `--env` shows what it detected and where each provider resolves to.
- **`llm-sync`** — finds `.devcontainer` folders across the workspace (`LLM_SYNC_ROOTS` overrides
  my roots) and copies the renderer in as `setup_pi.sh`, with `providers/` beside it. Docker can't
  follow symlinks out of the build context, so the config is propagated as real files, not links.

## The provider seam

The agent reads one `models.json`. 

I don't write it by hand — it's rendered from `config/providers/*.json`, one file per backend.

`config/master_setup_pi.sh` merges those files and rewrites each backend's host for the environment
it's rendering into. Each provider file declares its own host env var and default, so the renderer
never special-cases a backend by name.

Adding a backend — Ollama, a vLLM endpoint, anything OpenAI-compatible — is a new JSON file. No code
changes. That's the whole design: the renderer is generic, the provider files are data.

```
config/providers/ollama.agentic.json  ─┐
config/providers/diffusion.json        ─┼─►  master_setup_pi.sh  ─►  ~/.pi/agent/models.json
(one file per backend, declares host)  ─┘    (merge + host rewrite)   (what the agent reads)
```

### Where the host comes from

Every provider's `_defaultHost` is written for the place most of my agents live: a Linux
devcontainer, reaching the host over the Docker bridge (`http://172.17.0.1:<port>`). That address
is wrong anywhere else, so the entrypoints first work out where they are (`detect_agent_env`), and
the renderer keeps the default's **port** but swaps the **host**:

| Where the agent runs | Detected by | Host it gets |
|---|---|---|
| Linux devcontainer | `/.dockerenv` (or `REMOTE_CONTAINERS` set), any other kernel | `172.17.0.1` — the default, unchanged |
| Docker Desktop (Mac or WSL2) / OrbStack container | `/.dockerenv` (or `REMOTE_CONTAINERS`) + a kernel release containing `linuxkit`, `orbstack`, `microsoft` or `WSL2` | `host.docker.internal` |
| podman container, rootless or rootful | `/run/.containerenv` (checked first) | `host.containers.internal` |
| Bare host shell, Linux or Mac | no container marker | `localhost` |

`LLM_AGENT_ENV=devcontainer|docker-desktop|podman|host` forces one. That's needed under Colima and
similar VMs, which look like a plain Linux container from inside. It's also needed for a plain Docker
Engine installed *inside* WSL2 (no Docker Desktop). That one has the WSL2 kernel too, so it gets
detected as Docker Desktop. Set `devcontainer` there if `host.docker.internal` doesn't resolve.

A provider's own env var (`OLLAMA_HOST`, `DIFFUSION_HOST`) still wins over all of that. Its value is
normalised first, though, because `OLLAMA_HOST` is two things at once. To the Ollama server it's the
**bind address**, and on my box that's `0.0.0.0` (see `systemd/ollama.override.conf`). To a client
it's where to connect. So:

| `OLLAMA_HOST` value | Becomes |
|---|---|
| `0.0.0.0`, `0.0.0.0:11434`, `[::]`, `:11434` | this environment's host (above), port kept or defaulted |
| `gpubox` | `http://gpubox:11434` — scheme and default port added |
| `gpubox:9000` | `http://gpubox:9000` |
| `http://10.0.0.5:11434/v1/` | `http://10.0.0.5:11434` — trailing `/v1` trimmed, so no `/v1/v1` |
| `https://llm.example.org`, `http://gpubox` | kept as-is; with an explicit scheme no port is invented (80/443, as Ollama's own client reads it) |
| `::1` | `http://[::1]:11434` — a bare IPv6 address gets its brackets |

Then `/v1` is appended. The renderer itself does no detection; it takes `LLM_AGENT_ENV` and treats
unset as `devcontainer`. That keeps its output deterministic, and it's why the golden fixture in
`tests/` didn't change.

## Where this sits in the stack

This repo owns **everything about local models**: the servers, their tuning, the model roster, and
the renderer that turns the roster into an agent's config.

My `dev-env` repo (nvim / tmux / shell, plus Claude Code preferences, rolled out sudo-free per user
and into containers) deliberately does **not** install or configure Ollama. The server needs
root, systemd and a GPU driver, and it's one per host. Containers are clients. Neither fits a
per-user dotfiles rollout.

The scbio-docker project templates are the **delivery channel** into containers: they carry the
`.devcontainer/` that `llm-sync` drops `setup_pi.sh` + `providers/` into.

Known drift, not fixed here (it lives in the other repos):

- scbio-docker's template ships its own `models.agentic.json` — the pre-3.1 single-file list.
- Some projects still carry a stale, hand-written `configure_pi_models.sh` that lists reasoning-only
  models (FuseO1, DeepSeek-R1), against the agentic-only policy. Those 400 when Pi tries to
  tool-call them.

The single source of truth should be this repo's `config/providers/`. The fix is for those copies to
go and `llm-sync` to be the only way the list gets into a project.

## Why it's shaped this way

- **One responsibility per tool.** Secrets, notifications, model loading, and monitoring don't
  bleed into each other.
- **Config is data, code is generic.** New models and new backends are edits to JSON, not to scripts.
  The same goes for a new *place* to run an agent: a row in the host table, not a new provider.
- **Server and client are separate.** The server is one per box and needs root; clients are
  everywhere and need nothing but `jq`. Only the client half travels into containers.
- **Measured, not guessed.** "Loaded" means Ollama's own `/api/ps` lists the model, with how much
  of it is on the GPU — not that the load request was accepted.
- **Hysteresis in monitoring.** Warm and cool thresholds (90% / 85%) stop the watchdog flapping.
- **Portable on purpose.** Everything a Mac can reach runs on its stock bash 3.2 and BSD tools; CI
  runs the suite there.

## Quickstart

```bash
llm-status                       # what's resident right now
llm-manage load qwen3.6-dense    # load a model with its pinned context
llm-manage flush                 # clear the GPU
gpu-switch diffusion             # switch the card to the diffusion server (Linux/NVIDIA)
llm-agent-config                 # (re)render this shell's ~/.pi/agent/models.json
llm-sync                         # push config to devcontainers after editing providers/
```
