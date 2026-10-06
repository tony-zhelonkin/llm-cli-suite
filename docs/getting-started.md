# Getting started — walking the whole path

This walks the exact path I took: from a bare workstation to an Ollama model serving my coding
agent, and then to the DiffusionGemma server as a second backend. Follow it step by step and you
end up where I am.

On a Mac, skip to [On a Mac](#on-a-mac); Parts 1–2 are the Linux/NVIDIA path.

First read [Make it yours](#make-it-yours) at the bottom — a few paths and model names are specific
to my box, and you'll want to change them before you start.

---

## Part 1 — the Ollama tier (the daily driver)

### 1. Install Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

### 2. Tune it globally (before pulling anything)

The tuning is what lets a 30–35B model keep a full 128k window inside 32GB. It lives in
`systemd/ollama.override.conf`:

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo cp systemd/ollama.override.conf /etc/systemd/system/ollama.service.d/override.conf
# edit OLLAMA_MODELS to point at wherever you keep models (mine is /data2/llm-local)
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

What it sets, and why, is in [`ollama-tuning.md`](ollama-tuning.md): `q8_0` KV-cache quantization,
flash attention, keep-alive, and the storage path.

### 3. Pull a model

```bash
ollama pull qwen3.6:35b        # or whichever model fits your card
```

### 4. Bake context and samplers into it

A pulled model still boots with its default (often huge) context, which is how the KV cache blows
past the VRAM budget. I bake a fixed `num_ctx` and samplers into a Modelfile so every load is
predictable. The ones I use are in `modelfiles/`:

```bash
ollama create qwen3.6:35b -f modelfiles/qwen3.6_35b.mf
```

The reasoning is in [`modelfile-surgery.md`](modelfile-surgery.md).

### 5. Load it with the toolkit

```bash
llm-manage load qwen3.6-moe      # or: llm-manage load qwen3.6:35b 131072
llm-status                       # confirm it's resident on the GPU
```

`llm-manage` flushes whatever was resident, loads the model with a pinned context, and waits until
it's physically hot in VRAM (not just "accepted"). One model on the card at a time.

That's the whole daily tier. If you only want local Ollama models, you're done — point your agent at
`http://localhost:11434/v1` (or the render below).

---

## Part 2 — the DiffusionGemma server (a second backend)

This is optional and heavier. It's a diffusion LLM served by vLLM, sitting alongside Ollama. The
full story of getting it onto a frozen-driver box is in
[`story-serving-a-diffusion-llm.md`](story-serving-a-diffusion-llm.md); this is just the steps.

### 1. Build the vLLM venv

```bash
serving/diffusion/build-venv.sh          # builds + verifies at /data1/venvs/diffusion
```

The stack is pinned `+cu129` on purpose — see [`serving/diffusion/README.md`](../serving/diffusion/README.md)
for why (it's tied to a frozen driver; yours may differ, see Make it yours).

### 2. Get the model

The venv includes the Hugging Face CLI. The W4A16 int4 build is what fits 32GB with a real context:

```bash
/data1/venvs/diffusion/bin/hf download \
  pixelkaiser/diffusiongemma-26B-A4B-it-AWQ-MLP-W4A16-G64-S32-L1024
```

### 3. Install the server + switch the GPU to it

```bash
sudo cp systemd/diffusiongemma.service /etc/systemd/system/   # edit User= to yours first
sudo systemctl daemon-reload
gpu-switch diffusion                     # stops Ollama, drains the card, starts vLLM, waits for ready
```

Full runbook (firewall, testing, handing the GPU back): [`diffusiongemma-testing.md`](diffusiongemma-testing.md).

---

## Part 3 — point your agent at the models

The agent reads one `models.json`, rendered from `config/providers/*.json`:

```bash
llm-agent-config --env     # where am I, and where does each provider resolve to?
llm-agent-config --print   # preview (diff it against the current one if you have one)
llm-agent-config           # write ~/.pi/agent/models.json
```

It works out where it's running and points each provider at the right host: `localhost` in a host
shell, the Docker bridge in a Linux container, `host.docker.internal` under Docker Desktop. The rules
are in [`architecture.md`](architecture.md#where-the-host-comes-from). If `OLLAMA_HOST=0.0.0.0` is
set in your shell (it's the server's bind address on my box), that's normalised to something a
client can connect to rather than written out as `http://0.0.0.0`.

For an agent inside a devcontainer, `llm-sync` copies the config into each project so it reaches the
host models over the Docker bridge — see [`devcontainer-ollama-passthrough.md`](devcontainer-ollama-passthrough.md).

---

## On a Mac

The same server/client split, smaller: Ollama on Metal is the server, your shell (and any Docker
Desktop container) is the client. There's no diffusion server and no `gpu-switch` on a Mac. They're
NVIDIA/CUDA, and `install.sh` skips them.

### 1. Install Ollama

Either the app from [ollama.com](https://ollama.com/download), or `brew install ollama` and
`brew services start ollama`. Also `brew install jq` — the renderer needs it.

### 2. Tune it

Same knobs as the workstation, delivered through launchd instead of a systemd override. The quick
way, for the current login session:

```bash
launchctl setenv OLLAMA_FLASH_ATTENTION 1
launchctl setenv OLLAMA_KV_CACHE_TYPE q8_0
launchctl setenv OLLAMA_KEEP_ALIVE 30m
# quit and reopen Ollama.app so it reads them
```

`launchctl setenv` is forgotten at reboot, so to keep it, install the agent that re-applies it at
login — `launchd/com.tony.ollama-env.plist`, steps in [`launchd/README.md`](../launchd/README.md).
That's also where the brew-service variant is.

Keep-alive is `30m`, not the workstation's `-1`. On a Mac the model shares memory with everything
else, and pinning 20GB forever starves the desktop.

### 3. Pick models that fit *unified* memory

On the workstation the budget is the 32GB card, and system RAM is a separate (and slow) spill. On a
Mac there's one pool. The GPU gets a share of it (by default macOS lets it wire somewhere around
two-thirds to three-quarters of RAM), and macOS and your apps need the rest. So the question isn't
"does it fit 32GB" but "does it fit what's left":

These are worked out from the workstation numbers, not measured on a Mac. Treat them as a
starting point and check with `ollama ps`:

- My agent models are 15–23GB resident at 128k with `q8_0` KV. On a 36GB Mac that's tight: the
  `qwen3.6:35b-a3b` MoE fits, but drop `num_ctx` to 32k–64k for the dense 27B.
- 48GB and up runs the same list as the workstation.
- 16–24GB: stay with the ~8–14B tier, and don't expect 128k.

`ollama ps` after a load shows how much landed on the GPU — `100% GPU` is what you want. A CPU/GPU
split means it didn't fit. The memory math is the same as on the card, see
[`memory_physics.md`](memory_physics.md).

### 4. Install the tools and point the agent

```bash
./install.sh            # links the portable tools, loads the watchdog as a launchd agent
llm-agent-config        # ~/.pi/agent/models.json → http://localhost:11434/v1
llm-manage load qwen3.6:35b-a3b 65536
llm-status              # RAM (unified), and what Ollama has resident
```

`llm-agent-config` also writes the diffusion provider, because it's in the roster. Its port just
won't answer on a Mac; leave it or drop `diffusion.json` from your copy.

For a devcontainer on Docker Desktop, `llm-sync` ships the same `setup_pi.sh` as on Linux
(`LLM_SYNC_ROOTS=~/projects llm-sync`, since my roots don't exist on your Mac). Inside, it detects
Docker Desktop and renders `host.docker.internal`. Ollama's default `127.0.0.1` bind is enough for
that; Docker Desktop forwards it.

---

## Make it yours

A handful of things are specific to my machine. Change these before you run anything:

| Where | What's mine | Change to |
|---|---|---|
| `bin/llm-sync` → `WORKSPACE_ROOTS` | `/data1/users/antonz/projects`, `/scratch/...`, `/data2/users` | the roots where *you* keep projects with `.devcontainer/` folders — or just set `LLM_SYNC_ROOTS` (colon-separated) |
| `bin/llm-manage` → alias `case` | `gemma`, `qwen3.6-dense`, `qwen3.6-moe`… → my model IDs | your own model aliases (or just pass full model IDs) |
| `systemd/ollama.override.conf` → `OLLAMA_MODELS` | `/data2/llm-local` | wherever you store Ollama models (Mac: `launchd/com.tony.ollama-env.plist`, default `~/.ollama/models`) |
| `config/providers/*.json` → model `id`s | my Ollama + diffusion models | the models you actually pulled |
| `systemd/diffusiongemma.service` → `User=`, `ExecStart` venv path | `antonz`, `/data1/venvs/diffusion` | your user and venv path |
| `serving/diffusion/` → the `+cu129` pin | tied to my frozen 565 driver | your driver's CUDA — a modern driver can use the default PyPI vLLM; see the serving README |
| the agent target | Pi at `~/.pi/agent/models.json` | your agent's config path and its `models.json` schema |

The tools and the provider seam are universal; the paths, model names, and the frozen-driver vLLM
pin are the local parts. Everything the toolkit *assumes* about your machine is in this table.
