# Running DiffusionGemma under Pi

The runbook for serving Google's DiffusionGemma (W4A16 int4) to the Pi coding agent and taking it
for a spin. The story of how it got here is in
[`story-serving-a-diffusion-llm.md`](story-serving-a-diffusion-llm.md).

Measured 2026-07-26: runs on the frozen 565 driver via the `+cu129` vLLM stack, ~31GB resident,
128k context, sole tenant of the GPU.

> [!warning] One tenant on the GPU at a time
> DiffusionGemma at ~31GB can't share the 32GB card with a resident Ollama model. Flip with
> `gpu-switch` — it stops the other server and waits for the card to drain first.

## The three pieces (already in the repo)

| Piece | File | Role |
|---|---|---|
| Provider | `config/providers/diffusion.json` | makes Pi list the model (auto-rendered by the seam) |
| Server | `systemd/diffusiongemma.service` | the `vllm serve` command on `:11435` |
| GPU mutex | `bin/gpu-switch` | frees the card, flips Ollama ⇄ DiffusionGemma |

## The vLLM venv (what actually serves the model)

The server runs from `/data1/venvs/diffusion` — the systemd unit's `ExecStart` points straight at
`/data1/venvs/diffusion/bin/vllm`. This venv is the runtime; without it the service can't start.
It carries a specific stack because the driver is frozen at 565: everything is `+cu129` (CUDA 12.9),
which runs on the 12.7 driver by minor-version compatibility. The plain PyPI `vllm`/`torch` are
built for CUDA 13 and won't load.

```bash
python3 -m venv /data1/venvs/diffusion
source /data1/venvs/diffusion/bin/activate

# torch trio — all +cu129, or vLLM's import dies (torchvision::nms / torchaudio .so)
pip install torch==2.11.0+cu129 torchvision==0.26.0+cu129 torchaudio==2.11.0+cu129 \
  --index-url https://download.pytorch.org/whl/cu129

# vLLM 0.26 — the cu129 wheel from the GitHub release (cp38-abi3 runs on 3.10)
pip install "https://github.com/vllm-project/vllm/releases/download/v0.26.0/vllm-0.26.0%2Bcu129-cp38-abi3-manylinux_2_28_x86_64.whl" \
  --extra-index-url https://download.pytorch.org/whl/cu129
```

Exact frozen set: `docs/agent-research/2026-07-26-diffusiongemma-cuda12-compat/venv_freeze_cu129.txt`.
Why this particular stack, and the driver story behind it, is in
[`story-serving-a-diffusion-llm.md`](story-serving-a-diffusion-llm.md).

## One-time host setup

Privileged host steps, written out so you run each yourself rather than through a wrapper. All
idempotent — safe to re-run after a `git pull`.

```bash
# 1. Install the server as a systemd unit, then reload systemd so it sees it.
#    Don't `enable` it — it must not autostart at boot and grab the GPU from Ollama.
sudo cp systemd/diffusiongemma.service /etc/systemd/system/
sudo systemctl daemon-reload

# 2. Let the Docker bridge reach the port (same rule Ollama needed on 11434).
#    Skip if `sudo ufw status` is inactive.
sudo ufw allow from 172.17.0.0/16 to any port 11435 proto tcp

# 3. Put gpu-switch on your PATH (install.sh does this too).
ln -sf "$PWD/bin/gpu-switch" ~/.local/bin/gpu-switch
```

After editing the unit, re-run step 1 only. Works for both host-shell and containerised Pi — on
Linux the bridge IP `172.17.0.1:11435` is reachable from the host itself.

## Test loop

```bash
gpu-switch diffusion    # stops Ollama, drains the card, starts vLLM, waits for ready
gpu-switch status       # confirm it's the tenant
```

Then re-render Pi's config so it lists the model, preview the change, apply it:

```bash
source config/master_setup_pi.sh
render_pi_models config/providers /tmp/models.new.json
diff <(jq -S . ~/.pi/agent/models.json) <(jq -S . /tmp/models.new.json)
cp /tmp/models.new.json ~/.pi/agent/models.json
```

Pick **"DiffusionGemma 26B W4A16 (diffusion agent, 128k)"** in Pi and drive it. Hand the GPU back
when done:

```bash
gpu-switch ollama
```

## What you're evaluating

The feel and quality of the diffusion decode, and whether tool-calling behaves under Pi. Context is
no longer the constraint at 128k. This is a single-stream config (`--max-num-seqs 1`,
`--enforce-eager`), so it's about behaviour, not multi-user throughput.

## Next, if it earns its place

- Decide whether it's an agentic model or a chat-only one, and promote it out of the experimental corner.

`gpu-switch` stays: one 32GB card holds one model at a time. Running Ollama and diffusion together
is a question for a second GPU, not something to squeeze onto this one.
