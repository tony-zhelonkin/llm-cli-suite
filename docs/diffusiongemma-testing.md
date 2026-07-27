# Testing DiffusionGemma under Pi (experimental)

**Goal:** get a *feel* for Google DiffusionGemma as a Pi coding-agent backend on the local box,
This is the W4A16 int4 build (the quant hunt succeeded — Marlin kernels run the diffusion
arch on Ada; FP8's 14k ceiling is retired). Measured 2026-07-26: runs on the frozen 565 driver via the `+cu129` vLLM stack, **~31GB resident, 128k context (W4A16 int4), exclusive use of the GPU for now**.

> [!warning] One tenant on the GPU at a time
> DiffusionGemma (~31GB resident at util 0.90) cannot yet share the 32GB card with a resident Ollama model. Always flip
> with `gpu-switch` — it stops the other server and waits for the card to drain first.

## The three pieces (already in this repo)
| Piece | File | Role |
|---|---|---|
| Provider registration | `config/providers/diffusion.json` | makes Pi list the model (auto-rendered by the seam) |
| Server unit | `systemd/diffusiongemma.service` | the verified `vllm serve` command on `:11435` |
| GPU mutex | `bin/gpu-switch` | frees the card, flips Ollama ⇄ DiffusionGemma |

## One-time host setup (explicit — run each yourself)

These are privileged host mutations, so they are written out plainly rather than hidden behind a
wrapper: read each line, then run it. All are idempotent (safe to re-run, e.g. after a `git pull`).

```bash
# 1. Install the vLLM server as a systemd unit. Copy the file, then reload systemd so it sees it.
#    Do NOT `enable` it — it must not autostart at boot and grab the GPU from Ollama.
sudo cp systemd/diffusiongemma.service /etc/systemd/system/
sudo systemctl daemon-reload

# 2. Firewall: let the Docker bridge subnet reach the vLLM port (same rule Ollama needed on 11434).
#    Skip this if `sudo ufw status` shows "inactive" — then nothing is filtering the bridge anyway.
sudo ufw allow from 172.17.0.0/16 to any port 11435 proto tcp

# 3. Put gpu-switch on your PATH (mirrors how llm-manage/llm-status are linked into ~/.local/bin).
#    No sudo — it's your own user PATH.
ln -sf "$PWD/bin/gpu-switch" ~/.local/bin/gpu-switch
```

To refresh the unit after editing `systemd/diffusiongemma.service`, re-run step 1 only.
Works for **both** host-shell Pi and containerised Pi — on Linux the bridge IP `172.17.0.1:11435`
is reachable from the host itself, so no separate host config is needed.

## Test loop
```bash
# hand the GPU to DiffusionGemma (stops Ollama, waits for drain, starts vLLM)
gpu-switch diffusion
gpu-switch status                         # confirm it's the tenant
# wait for load (~1-2 min), then:
curl -s localhost:11435/v1/models | jq '.data[].id'      # ready check
```
Then in your project devcontainer, Pi's `~/.pi/agent/models.json` already lists
**"DiffusionGemma 26B W4A16 (diffusion agent, 128k)"** (the diffusion provider renders automatically).
Pick it in Pi's model selector and drive it like any other model — full 128k window — a real agentic context.

```bash
# when done, hand the GPU back to your normal coding tier
gpu-switch ollama
```

## What you're evaluating (and what NOT to conclude from it)
- **Feel / quality of the diffusion decode** and whether tool-calling behaves under Pi.
- **NOT** multi-user throughput — this is `--max-num-seqs 1`, `--enforce-eager`. Context is no
  longer the constraint (128k). Quality: W4A16 recovers less than FP8 — benchmark before trusting
  for hard tasks.

> [!success] W4A16 int4 gives a real 128k window
> FP8 (26GB weights) only left ~14k context and Pi autocompacted ~10k — unusable as an agent.
> The W4A16 quant (~15GB weights, Marlin int4 kernels verified on Ada) leaves ~13GB for KV →
> **128k context**. This is the daily-driver config; FP8 is kept only as a precision fallback.

## If you decide to keep going
- Context too tight → find an **INT4/AWQ/GPTQ** DiffusionGemma vLLM can serve on Ada (~13GB → bigger
  KV, maybe even Ollama co-residency, which would retire `gpu-switch`). **NVFP4 stays excluded**
  (Blackwell-only). Track under the rollout plan's Phase 0 follow-ups.
- Happy with it → promote from experimental: raise `contextWindow` if the quant changes, and decide
  the agentic-vs-chat policy (ADR-003).
