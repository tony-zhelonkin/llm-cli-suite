# Running DiffusionGemma under Pi

The runbook for serving Google's DiffusionGemma (W4A16 int4) to the Pi coding agent 
and taking it for a spin. 

The story of how it got here is in
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
`/data1/venvs/diffusion/bin/vllm`. This venv is the runtime; without it the service can't start. Its
definition lives in the repo under [`serving/diffusion/`](../serving/diffusion/) (pinned
requirements + lockfile + builder), so it's reproducible rather than hand-built.

```bash
serving/diffusion/build-venv.sh          # builds + verifies at the default path
LOCK=1 serving/diffusion/build-venv.sh   # byte-exact rebuild from the lockfile
```

Everything is pinned `+cu129` because the driver is frozen at 565 — the whole story, and why that
matters, is in [`serving/diffusion/README.md`](../serving/diffusion/README.md) and
[`story-serving-a-diffusion-llm.md`](story-serving-a-diffusion-llm.md).

## One-time host setup

Privileged host steps, written out so you run each yourself rather than through a wrapper. All
idempotent — safe to re-run after a `git pull`.

```bash
# 1. Install the server as a systemd unit, then reload systemd so it sees it.
#    Don't `enable` it — it must not autostart at boot and grab the GPU from Ollama.
sudo cp systemd/diffusiongemma.service /etc/systemd/system/
sudo systemctl daemon-reload

# 2. Let containers reach the port. Mirror the rule Ollama already uses on 11434
#    (`sudo ufw status numbered | grep 1143` — Ollama's is ALLOW from Anywhere).
#    Skip if `sudo ufw status` is inactive.
sudo ufw allow 11435/tcp comment 'DiffusionGemma vLLM API'

# 3. Put gpu-switch on your PATH (install.sh does this too).
ln -sf "$PWD/bin/gpu-switch" ~/.local/bin/gpu-switch
```

After editing the unit, re-run step 1 only. Works for both host-shell and containerised Pi — on
Linux the host owns `172.17.0.1`, so `172.17.0.1:11435` is reachable from the host itself.

> [!warning] Don't scope the firewall to `172.17.0.0/16`
> That's the *default* Docker bridge. A Compose-managed devcontainer gets its **own** network
> (`192.168.x`, `172.18`–`172.31`, …), so its packets never match a `172.17.0.0/16` rule — they get
> silently dropped and the agent times out, even though `172.17.0.1` still routes. Mirror Ollama's
> open `11435/tcp` rule (above), or, to tighten both ports, scope to the two pools Compose draws from:
> `sudo ufw allow from 172.16.0.0/12 to any port 11435 proto tcp` **and** `from 192.168.0.0/16`.

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

## The verdict (2026-07-27): good decode, unreliable agent

Drove it under Pi, host and container. **The infrastructure is sound** — every real Pi request
returns 200, and the `gemma4` parser returns clean structured `tool_calls` in both streaming and
non-streaming when the model emits one (verified with a direct `curl` to `:11435`). Tool calls *do*
execute.

**But it's inconsistent at agentic tool use.** A diffusion decoder denoises a whole canvas at once,
so sometimes the output lands cleanly on the `gemma4` tool-call tokens (the parser extracts it, the
call runs) and sometimes it lands off them — the raw `call:bash{command:<|"|>…<|"|>}` delimiters
leak into chat as plain text, or the command comes out malformed (`ls -F *}`), or it forgets it
already called and apologizes. This is inherent to a **diffusion** model at an **aggressive int4
quant**, and there's little to steady it: vLLM **rejects `temperature`, `min_p`, `seed`,
`min_tokens`, `logit_bias`** for diffusion models (400), so the usual sampling knobs are off the
table.

So: a capable *chat / reasoning* model with a genuinely novel decode, not a dependable *agent* on
this quant. Multi-step tool-driven work still belongs on the Ollama Qwen/Gemma models.

> [!note] Client constraint for diffusion endpoints
> Any client pointed at `:11435` must **not** send `temperature`/`min_p`/`seed`/`min_tokens`/
> `logit_bias` — vLLM 400s on them for diffusion models. Pi doesn't send them (all its requests are
> 200); a hand-rolled `curl` or a differently-configured client will need them omitted.

## Next, if it earns its place

- Treat it as chat/reasoning, not agentic, until a stronger quant or a maturer diffusion tool-call
  path lands. Re-test tool reliability when either changes.

`gpu-switch` stays: one 32GB card holds one model at a time. Running Ollama and diffusion together
is a question for a second GPU, not something to squeeze onto this one.
