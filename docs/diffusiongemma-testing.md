# Testing DiffusionGemma under Pi (experimental)

**Goal:** get a *feel* for Google DiffusionGemma as a Pi coding-agent backend on the local box,
before deciding whether to hunt a better quant. This is the FP8 build measured in Phase 0
(2026-07-26): runs on the frozen 565 driver via the `+cu129` vLLM stack, **~31GB resident, 8k
context, exclusive use of the GPU**.

> [!warning] One tenant on the GPU at a time
> FP8 DiffusionGemma (~31GB) cannot share the 32GB card with a resident Ollama model. Always flip
> with `gpu-switch` — it stops the other server and waits for the card to drain first.

## The three pieces (already in this repo)
| Piece | File | Role |
|---|---|---|
| Provider registration | `config/providers/diffusion.json` | makes Pi list the model (auto-rendered by the seam) |
| Server unit | `systemd/diffusiongemma.service` | the verified `vllm serve` command on `:11435` |
| GPU mutex | `bin/gpu-switch` | frees the card, flips Ollama ⇄ DiffusionGemma |

## One-time host setup
```bash
# 1. install the unit (do NOT enable — must not autostart and grab the GPU)
sudo cp systemd/diffusiongemma.service /etc/systemd/system/
sudo systemctl daemon-reload

# 2. let the Docker bridge reach :11435 (same rule Ollama needed on 11434)
sudo ufw allow from 172.17.0.0/16 to any port 11435 proto tcp

# 3. put gpu-switch on PATH (or call bin/gpu-switch directly)
sudo ln -sf "$PWD/bin/gpu-switch" /usr/local/bin/gpu-switch
```

## Test loop
```bash
# hand the GPU to DiffusionGemma (stops Ollama, waits for drain, starts vLLM)
gpu-switch diffusion
gpu-switch status                         # confirm it's the tenant
# wait for load (~1-2 min), then:
curl -s localhost:11435/v1/models | jq '.data[].id'      # ready check
```
Then in your project devcontainer, Pi's `~/.pi/agent/models.json` already lists
**"DiffusionGemma 26B FP8 (EXPERIMENTAL · 8k ctx)"** (the diffusion provider renders automatically).
Pick it in Pi's model selector and drive it like any other model — mind the 8k window.

```bash
# when done, hand the GPU back to your normal coding tier
gpu-switch ollama
```

## What you're evaluating (and what NOT to conclude from it)
- **Feel / quality of the diffusion decode** and whether tool-calling behaves under Pi.
- **NOT** speed-at-scale or long-context behaviour — this is `--max-num-seqs 1`, 8k ctx,
  `--enforce-eager` (no CUDA graphs), all forced by the FP8 VRAM squeeze. A roomier INT4/AWQ quant
  (the follow-up hunt) would lift the context and let CUDA graphs back on.

## If you decide to keep going
- Context too tight → find an **INT4/AWQ/GPTQ** DiffusionGemma vLLM can serve on Ada (~13GB → bigger
  KV, maybe even Ollama co-residency, which would retire `gpu-switch`). **NVFP4 stays excluded**
  (Blackwell-only). Track under the rollout plan's Phase 0 follow-ups.
- Happy with it → promote from experimental: raise `contextWindow` if the quant changes, and decide
  the agentic-vs-chat policy (ADR-003).
