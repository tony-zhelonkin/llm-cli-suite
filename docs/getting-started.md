# Getting started — walking the whole path

This walks the exact path I took: from a bare workstation to an Ollama model serving my coding
agent, and then to the DiffusionGemma server as a second backend. Follow it step by step and you
end up where I am.

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
source config/master_setup_pi.sh
render_pi_models config/providers ~/.pi/agent/models.json    # preview/diff first if it exists
```

For an agent inside a devcontainer, `llm-sync` copies the config into each project so it reaches the
host models over the Docker bridge — see [`devcontainer-ollama-passthrough.md`](devcontainer-ollama-passthrough.md).

---

## Make it yours

A handful of things are specific to my machine. Change these before you run anything:

| Where | What's mine | Change to |
|---|---|---|
| `bin/llm-sync` → `WORKSPACE_ROOTS` | `/data1/users/antonz/projects`, `/scratch/...`, `/data2/users` | the roots where *you* keep projects with `.devcontainer/` folders |
| `bin/llm-manage` → alias `case` | `gemma`, `qwen3.6-dense`, `qwen3.6-moe`… → my model IDs | your own model aliases (or just pass full model IDs) |
| `systemd/ollama.override.conf` → `OLLAMA_MODELS` | `/data2/llm-local` | wherever you store Ollama models |
| `config/providers/*.json` → model `id`s | my Ollama + diffusion models | the models you actually pulled |
| `systemd/diffusiongemma.service` → `User=`, `ExecStart` venv path | `antonz`, `/data1/venvs/diffusion` | your user and venv path |
| `serving/diffusion/` → the `+cu129` pin | tied to my frozen 565 driver | your driver's CUDA — a modern driver can use the default PyPI vLLM; see the serving README |
| the agent target | Pi at `~/.pi/agent/models.json` | your agent's config path and its `models.json` schema |

The tools and the provider seam are universal; the paths, model names, and the frozen-driver vLLM
pin are the local parts. Everything the toolkit *assumes* about your machine is in this table.
