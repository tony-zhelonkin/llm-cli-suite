# DevContainer → Host Ollama Passthrough (Pi agent over local models)

> **What this is**: how to make the Pi coding agent *inside a Docker devcontainer* talk to the
> Ollama server running on the *host* workstation, so a containerised project uses the local
> models over the Docker bridge instead of the internet. This is the container case; running Pi
> in a plain host shell is simpler and covered at the end.

---

## The mental model

Three isolated environments have to line up:

```
Host workstation                 Docker bridge            Container
─────────────────                ─────────────            ─────────
ollama.service                                            pi agent
  binds 0.0.0.0:11434   ◄──────  172.17.0.1  ◄──────────  reads OLLAMA_HOST
  (systemd override)             (gateway IP)             writes ~/.pi/agent/models.json
```

`172.17.0.1` is the **Docker bridge gateway** — the address a Linux container uses to reach a
service on the host. (On Docker Desktop / Mac it is `host.docker.internal`; on native Linux it is
the bridge IP, usually `172.17.0.1`.) For the container to reach the host Ollama, three things
must all be true, and each is a separate failure point:

1. Ollama on the host is **listening on all interfaces**, not just localhost.
2. The host **firewall** lets the bridge subnet reach port 11434.
3. The container **knows the address** (`OLLAMA_HOST`) and Pi's `models.json` points at it.

---

## Step 1 — Host: bind Ollama to 0.0.0.0

In the systemd override (`systemd/ollama.override.conf`, see [ollama-tuning.md](ollama-tuning.md)):

```ini
Environment="OLLAMA_HOST=0.0.0.0"
```

```bash
sudo systemctl daemon-reload && sudo systemctl restart ollama.service
```

Without this, Ollama listens only on `127.0.0.1` and the container's packets never arrive.

> Security: `0.0.0.0` exposes the un-authenticated API to every interface, gated only by the host
> firewall. On a box used purely for local/SSH inference, prefer `127.0.0.1`. See `SECURITY.md`.

## Step 2 — Host: open the firewall for the bridge

Even with Ollama on `0.0.0.0`, a hardened host drops the container's packets until you allow the
port. This was a real, silent timeout the first time:

```bash
sudo ufw allow 11434/tcp comment 'Ollama API (Docker bridge)'
```

## Step 3 — Container: hand it the bridge address

In the project's `devcontainer.json`:

```json
"containerEnv": {
    "OLLAMA_HOST": "http://172.17.0.1:11434"
}
```

This env var is what both the verification below and the setup script read.

## Step 4 — Container: install Pi and write its model list on start

This is the step that is easy to get wrong. The container home directory is **not persisted
across rebuilds**, so Pi and its `~/.pi/agent/models.json` must be re-established on every start
by a `postStartCommand` — not a one-time manual step.

In this workstation's setup, one script does it: **`setup_ai_env.sh`** (shipped by scbio-docker
into `.devcontainer/scripts/`). It installs the AI CLIs (Claude, Codex, opencode, Pi, Antigravity)
and writes `~/.pi/agent/models.json` from the adjacent **`models.agentic.json`** — the single
source of truth for the agentic (tool-capable) model list — rewriting the Ollama `baseUrl` to the
container's `OLLAMA_HOST`.

Wire it into `devcontainer.json`:

```json
"postStartCommand": "bash -lc 'chmod +x .devcontainer/scripts/setup_ai_env.sh && .devcontainer/scripts/setup_ai_env.sh'"
```

> **Gotcha I hit:** if `postStartCommand` only runs the sanity check (or nothing AI-related),
> the container comes up with `OLLAMA_HOST` set but **no `~/.pi/agent/models.json`** — so Pi has
> no models and silently fails to see the host Ollama. The env var alone is not enough; something
> has to write the config each start.

The resulting `~/.pi/agent/models.json` looks like this (baseUrl on the bridge, OpenAI-compat
shim, Ollama's `developer` role and reasoning-effort disabled):

```json
{
  "providers": {
    "ollama": {
      "baseUrl": "http://172.17.0.1:11434/v1",
      "api": "openai-completions",
      "apiKey": "ollama",
      "compat": { "supportsDeveloperRole": false, "supportsReasoningEffort": false },
      "models": [
        { "id": "batiai/qwen3.6-27b:iq4", "name": "Qwen 3.6 27B Dense (Primary Agent)", "reasoning": false, "contextWindow": 131072 }
        // ... agentic/tool-capable models only
      ]
    }
  }
}
```

Only **tool-capable** models belong here. Reasoning-only models (FuseO1, DeepSeek-R1) are left
out on purpose — Pi tries to tool-call them and gets a 400. They live in Continue/chat configs,
not in an agent's model list.

---

## Verify from inside the container

```bash
# 1. Can the container reach the host Ollama at all?
curl -s http://172.17.0.1:11434/api/tags | jq '.models[].name'
#    → list of models  = bridge + firewall + 0.0.0.0 all good
#    → connection refused / timeout = step 1 or 2 failed

# 2. Did the model list get written?
cat ~/.pi/agent/models.json | jq '.providers.ollama.baseUrl, (.providers.ollama.models|length)'

# 3. Does Pi see them?
pi   # then inside: /model
```

---

## The simpler case: Pi in a plain host shell (no container)

No bridge, no firewall, no `containerEnv`. Ollama is already on `localhost:11434`, so Pi's
`models.json` just points at `http://localhost:11434/v1`. The host's hand-maintained
`~/.pi/agent/models.json` is exactly this. Everything above is only needed to cross the container
boundary.

---

## TL;DR

- Container reaches host Ollama at **`172.17.0.1`** (Linux bridge gateway) — needs Ollama on
  `0.0.0.0` **and** `ufw allow 11434` **and** `OLLAMA_HOST` set in `devcontainer.json`.
- Container home is ephemeral: a **`postStartCommand`** must reinstall Pi and rewrite
  `~/.pi/agent/models.json` every start. `OLLAMA_HOST` alone does nothing.
- The model list comes from one file — `models.agentic.json` (agentic/tool-capable only) — with
  `baseUrl` rewritten to the container's `OLLAMA_HOST`.
- Host-shell Pi is the easy case: just point `baseUrl` at `localhost:11434/v1`.
