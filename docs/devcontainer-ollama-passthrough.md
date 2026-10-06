# DevContainer → host GPU models (Ollama *and* diffusion)

> **What this is:** how a coding agent (Pi) running *inside a Docker devcontainer* talks to a model
> served on the *host workstation's GPU* — over the Docker network, not the internet. It covers both
> backends the same way: Ollama on `:11434` and the vLLM diffusion server on `:11435`. Running Pi in
> a plain host shell is the easy case, at the end.

This is written from my own setup on one 32GB-GPU workstation with ~two dozen Compose-managed
devcontainers. Every claim here I hit and verified on this box.

---

## The mental model

Four things have to line up. Each is a separate, silent failure point.

```
Host workstation                    Docker network              Container (a Compose project)
────────────────                    ──────────────              ─────────────────────────────
one GPU, one model hot:                                         pi agent
  ollama.service   0.0.0.0:11434 ◄──┐                           reads its models.json
    OR                               ├── 172.17.0.1 ◄────────── talks to the host
  diffusiongemma   0.0.0.0:11435 ◄──┘   (host-owned IP)         (rendered each start)
  (gpu-switch flips between them)
```

1. **The GPU holds one model at a time.** Ollama and the diffusion server can't co-reside on 32GB,
   so `gpu-switch` runs exactly one. Whichever is *not* hot has a dead port.
2. The hot server **binds `0.0.0.0`**, not just localhost, so packets from outside the host arrive.
3. The host **firewall** lets the container's subnet reach the port.
4. The container **knows the address** and its `models.json` lists the provider pointing at it.

---

## The address: why `172.17.0.1` works from every container

`172.17.0.1` is the gateway of Docker's **default** bridge. The instinct is "that's the address a
container uses to reach the host" — and that's only half true here.

Compose doesn't put projects on the default bridge. Each project gets its **own** network:

```
sting-jr_devcontainer_default   → 192.168.112.0/20, gateway 192.168.112.1
meta-aging_devcontainer_default → 192.168.128.0/20, gateway 192.168.128.1
12868-eh_devcontainer_default   → 172.20.0.0/16,    gateway 172.20.0.1
… (each project a different subnet, drawn from 172.16.0.0/12 and 192.168.0.0/16)
```

So a container's own gateway is `192.168.112.1`, not `172.17.0.1`. Yet `172.17.0.1:11435` still
answers from inside every one of them. The reason: `172.17.0.1` is an address the **host itself
owns** (it's the host's IP on docker0). A container's packet to it is routed to the host like any
other host IP, across whatever docker interface the container sits on. So one stable address —
`172.17.0.1` — reaches the host from any project, and that's what the provider config uses. (Each
project's own gateway, e.g. `192.168.112.1`, works too, but it differs per project, so it's not
useful as a shared default.)

**This is the trap** → the address routing everywhere does *not* mean the firewall lets it through
everywhere. See the next section.

---

## Step 1 — Host: bind the server to `0.0.0.0`

**Ollama** — in the systemd override (`systemd/ollama.override.conf`, see
[ollama-tuning.md](ollama-tuning.md)):

```ini
Environment="OLLAMA_HOST=0.0.0.0"
```
```bash
sudo systemctl daemon-reload && sudo systemctl restart ollama.service
```

**Diffusion** — already handled: `systemd/diffusiongemma.service` runs `vllm serve … --host 0.0.0.0`.

Without `0.0.0.0` the server listens only on `127.0.0.1` and the container's packets never arrive.

> Security: `0.0.0.0` exposes an un-authenticated API on every interface, gated only by the host
> firewall. On a box used purely for local/SSH inference that's the trade-off; see `SECURITY.md`.

## Step 2 — Host: open the firewall for *all* the container subnets

This is the one that bit me. A hardened host silently **drops** the container's packets until the
port is allowed — and the allow has to match the container's **source subnet**.

Because each Compose project is on its own network (`192.168.x`, `172.18`–`172.31`, …), a rule
scoped to the default bridge `172.17.0.0/16` matches almost nothing. The packet routes fine, hits
the firewall, gets dropped, and the agent just says **`Request timed out`** — no error, no refusal.

Mirror Ollama's rule (open on the port), which is what makes it work from every project:

```bash
sudo ufw allow 11434/tcp comment 'Ollama API'
sudo ufw allow 11435/tcp comment 'DiffusionGemma vLLM API'
```

Check what you've got with `sudo ufw status numbered | grep 1143`. *Refused* from a container means
firewall-open-but-nothing-listening (that backend isn't the hot one). *Timeout* means the firewall
dropped it — the port or subnet isn't allowed.

> **Tighter alternative.** If open-on-the-port is too broad, scope to the two pools Compose draws
> from — but you need **both**, not just `172.17`:
> ```bash
> sudo ufw allow from 172.16.0.0/12  to any port 11435 proto tcp
> sudo ufw allow from 192.168.0.0/16 to any port 11435 proto tcp
> ```

## Step 3 — Container: render `models.json` on every start

The container home directory is **wiped on rebuild**, so Pi and its `~/.pi/agent/models.json` have
to be re-established every start by a `postStart` hook — never a one-time manual step.

In this setup one script does it: **`setup_pi.sh`**, shipped into each project's
`.devcontainer/scripts/` (with a `providers/` folder beside it) by `llm-sync`. On start it renders
`~/.pi/agent/models.json` from `config/providers/*.json` — one file per backend — rewriting each
provider's `baseUrl` to the container's bridge address. No provider is special-cased; adding a
backend is a new JSON file (that's the [architecture](architecture.md) seam).

The provider files declare their own host + default:

```jsonc
// ollama.agentic.json      _hostEnv: OLLAMA_HOST     _defaultHost: http://172.17.0.1:11434
// diffusion.json           _hostEnv: DIFFUSION_HOST   _defaultHost: http://172.17.0.1:11435
```

So the rendered `models.json` inside the container carries **both** backends on the bridge:

```
diffusion  →  http://172.17.0.1:11435/v1   pixelkaiser/diffusiongemma-26B-…-W4A16
ollama     →  http://172.17.0.1:11434/v1   qwen3.6:35b, qwen3-coder:30b, gemma4:31b, …
```

Wire the render into `devcontainer.json` (this box uses `setup_ai_env.sh` → `setup_pi.sh`):

```json
"postStartCommand": "bash -lc '.devcontainer/scripts/setup_ai_env.sh'"
```

> **Gotcha:** if `postStart` doesn't run the render, the container comes up with **no**
> `~/.pi/agent/models.json` and Pi silently sees no models. And if the `providers/` folder wasn't
> shipped next to `setup_pi.sh`, the renderer logs `No provider JSON files found — Skipping` and
> writes nothing. Re-run `llm-sync` on the host (it stages from `~/.scripts/providers`, symlinked
> to the repo by `install.sh`), then re-provision the container.

Only **tool-capable** models belong in an agent's list. Reasoning-only models get a 400 when Pi
tries to tool-call them, so they stay out.

---

## The GPU mutex, from the container's side

Both providers are always *listed* in `models.json`. Only the one the host has switched to actually
answers — the other's port is dead. So picking a model is two moves:

```bash
# on the HOST — hand the GPU to the backend you want
gpu-switch diffusion       # stops Ollama, drains VRAM, starts vLLM, waits until it's serving
# gpu-switch ollama        # …and back

# in the CONTAINER's Pi — pick a model served by whatever is now hot
```

Pick an Ollama model while the GPU is on diffusion (or vice-versa) and you get a **timeout** — the
backend simply isn't running. No container restart is needed to switch; the config already lists
both.

---

## Verify from inside the container

```bash
# 1. Can it reach the hot backend? (200 = bridge + firewall + 0.0.0.0 all good)
curl -s -m 5 -o /dev/null -w "http=%{http_code}\n" http://172.17.0.1:11435/v1/models   # diffusion
curl -s http://172.17.0.1:11434/api/tags | jq '.models[].name'                          # ollama

# 2. Did the model list get written, with both providers on the bridge?
jq -r '.providers | to_entries[] | .key + " → " + .value.baseUrl' ~/.pi/agent/models.json

# 3. Does Pi see them?
pi        # then inside: /model
```

`http=000` + a ~5s wait = timeout (Step 2 firewall, or that backend isn't the hot one). Instant
*refused* = firewall's open but nothing's listening there — run `gpu-switch` on the host.

---

## The easy case: Pi in a plain host shell (no container)

No bridge, no firewall, no `containerEnv`. The servers are already on `localhost`, so the host's
`~/.pi/agent/models.json` just points at `http://localhost:11434/v1` and `…:11435/v1`. Everything
above is only what it takes to cross the container boundary.

`llm-agent-config` writes exactly that. It sees it's not in a container and swaps the bridge for
`localhost`, keeping each provider's port.

## A Mac with Docker Desktop

There's no `172.17.0.1` from a Docker Desktop container to the Mac; the containers live in Docker's
own Linux VM. The way out is `host.docker.internal`, which Docker Desktop forwards to the Mac's
loopback, so Ollama's default `127.0.0.1` bind is enough and there's no firewall step. `setup_pi.sh`
spots Docker Desktop (and OrbStack) from the VM's kernel name and renders `host.docker.internal`
by itself. Under Colima or anything else it can't recognise, set `LLM_AGENT_ENV=docker-desktop` in
`containerEnv`. The rules are in [architecture.md](architecture.md#where-the-host-comes-from).

---

## TL;DR

- Host GPU runs **one** model at a time — `gpu-switch` flips Ollama (`:11434`) ⇄ diffusion
  (`:11435`). The idle one's port is dead; picking its model from a container = timeout.
- Container → host uses **`172.17.0.1`**: a host-owned IP that routes from any project's network,
  so it's the one stable address for all of them.
- Firewall must allow the port for **all** container subnets, not just `172.17.0.0/16` — Compose
  projects each get their own subnet. Mirror Ollama's open `11434`/`11435` rule, or allow both
  `172.16.0.0/12` and `192.168.0.0/16`.
- Container home is ephemeral: a **`postStart`** render (`setup_pi.sh` + shipped `providers/`)
  rewrites `~/.pi/agent/models.json` every start, listing every backend on the bridge.
- Host-shell Pi is trivial: `llm-agent-config` points `baseUrl` at `localhost`. A Docker
  Desktop container on a Mac gets `host.docker.internal` instead of the bridge.
</content>
</invoke>
