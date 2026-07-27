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

- Try co-residency: at ~15GB weights it might share the card with a 15GB Ollama model if diffusion
  KV is capped — that would retire `gpu-switch` for the pair.
- Decide whether it's an agentic model or a chat-only one, and promote it out of the experimental corner.
