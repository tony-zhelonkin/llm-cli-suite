# On-Demand Single-GPU MUX: Ollama XOR DiffusionGemma

> **Summary:** A tiny arbiter daemon enforces mutual exclusion on one GPU — before serving a request for endpoint B it fully unloads endpoint A's weights (Ollama via `keep_alive:0`/`ollama stop`; diffusion via `systemctl stop`), verifies VRAM is actually freed with `nvidia-smi`, then loads B. Only one ~18-23GB model is ever resident.

> **RECOMMENDED MVP (single-user local box):** Do **not** build a request-intercepting proxy first. Run Ollama with `OLLAMA_KEEP_ALIVE` default (or `0`) and put the diffusion server behind an **explicit `gpu-switch` CLI** (`gpu-switch ollama` / `gpu-switch diffusion`) plus a **socket-activated systemd unit** for the diffusion server. The user chose "on-demand mux" — an explicit switch is the simplest thing that cannot double-load the GPU, and cold-load latency (tens of seconds for 18GB) means an implicit lazy-load proxy mostly just hides that cost while adding failure modes. Add lazy auto-switch later only if the explicit command becomes annoying.

---

## 0. The problem

- One GPU, ~24GB usable VRAM (single-model-per-GPU architecture decision).
- `ollama.service` (systemd) bound `0.0.0.0:11434`, serves 15-23GB models to devcontainers over the Docker bridge `172.17.0.1`.
- New: DiffusionGemma served by a Python FastAPI + diffusion-runtime process on `:11435`, ~18GB VRAM.
- Constraint: the two together exceed VRAM. Exactly one may be resident at a time.

---

## 1. Forcing Ollama to release VRAM (verified)

Ollama's scheduler keeps a model in VRAM for **5 minutes by default** after the last request, then unloads it and frees the VRAM. You can override this globally or per-request. All of the following are documented Ollama behavior (see Sources):

| Mechanism | Scope | Effect | Speed |
|---|---|---|---|
| `OLLAMA_KEEP_ALIVE=0` (env on the service) | Global default | Model unloads **as soon as each request returns** | Immediate after each call |
| `OLLAMA_KEEP_ALIVE=5m` (default) | Global default | Unloads 5 min after last request | Delayed |
| `keep_alive: 0` in `/api/generate`\|`/api/chat`\|`/api/embed` body | Per-request | Unloads that model immediately after the response | Immediate |
| `ollama stop <model>` (CLI) | Explicit | Unloads named model now | Immediate |
| No-op request with `keep_alive:0` and empty prompt | Explicit | Triggers unload without generating | Immediate |

**Key facts (verified against Ollama FAQ + behavior write-ups):**

- `keep_alive` accepts a duration string (`"10m"`, `"24h"`), seconds (`3600`), any **negative** number = keep loaded forever (`-1`), or **`0`** = unload immediately after the response.
- **Per-request `keep_alive` overrides `OLLAMA_KEEP_ALIVE`.** Precedence is documented.
- **Critical gotcha:** to force-unload via API you must pass **the model name that is currently loaded**. Sending `keep_alive:0` with a *different* model name does not unload the resident one. When in doubt, enumerate loaded models via `/api/ps` and unload each. `ollama stop <model>` sidesteps the naming issue if you know the name.
- `OLLAMA_KEEP_ALIVE` is read **only at server startup** and only from the *service* environment (systemd `Environment=`), not your shell `.bashrc`. Changing it requires `daemon-reload` + `systemctl restart ollama`.
- Pinning caveat: `keep_alive:-1` will **not** be evicted automatically; if VRAM fills, Ollama returns a load error rather than evicting the pinned model. For a MUX, avoid `-1`.

**Recommended Ollama config for the MUX:** leave the service default at `OLLAMA_KEEP_ALIVE=5m` (fast repeat inference during an Ollama "session") and let the arbiter force an **explicit unload** (`ollama stop` + `/api/ps` verify) when switching to diffusion. If you want zero-residual-VRAM guarantees without an arbiter, set `OLLAMA_KEEP_ALIVE=0` so Ollama self-evicts after every call — at the cost of a cold reload on each request.

### Confirm VRAM is actually freed

`ollama ps` / `GET /api/ps` shows loaded models, their VRAM usage, and expiry — but the **ground truth is `nvidia-smi`**, because unload is asynchronous (the runner subprocess must exit and the driver must reclaim memory). Poll `nvidia-smi` until used memory drops below a threshold:

```bash
# Free VRAM (MiB) on GPU 0
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits -i 0
# Per-process VRAM (catch a runner that hasn't exited yet)
nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits
```

---

## 2. Start/stop the diffusion FastAPI server

**Prefer a systemd unit over an arbiter-managed subprocess.** systemd gives you clean start/stop, log capture, restart-on-crash, and—importantly—**socket activation**, which lets the server be *stopped* (0 VRAM) yet still "listen" on `:11435`; the first connection starts it. That is the cleanest on-demand primitive on Linux.

### 2a. Plain unit (arbiter calls `systemctl start/stop`)

`/etc/systemd/system/diffusiongemma.service`
```ini
[Unit]
Description=DiffusionGemma FastAPI server (single-GPU, on-demand)
After=network-online.target
# Hard interlock: cannot run at the same time as ollama (see note below)
Conflicts=ollama.service

[Service]
Type=notify                 # server calls sd_notify READY=1 once weights are loaded
NotifyAccess=all
User=antonz
Environment=CUDA_VISIBLE_DEVICES=0
Environment=HF_HOME=/data1/models/hf
ExecStart=/data1/venvs/diffusion/bin/python -m diffusiongemma.server --host 0.0.0.0 --port 11435
# Give the driver time to reclaim VRAM on stop
TimeoutStopSec=60
KillSignal=SIGINT
Restart=no

[Install]
WantedBy=multi-user.target
```

> Note on `Conflicts=ollama.service`: systemd `Conflicts` is a real interlock but it is **bidirectional and blunt** — starting diffusion would *stop ollama entirely*, dropping in-flight devcontainer requests. For a mux you usually want to unload the *model* (free VRAM) while keeping `ollama.service` alive to accept the next request. So prefer the arbiter-driven `ollama stop` approach and treat `Conflicts=` as a belt-and-suspenders safety net only if you're willing to fully stop Ollama. Pick one model, not both.

### 2b. Socket-activated (lazy start on first connection) — nice MVP

`/etc/systemd/system/diffusiongemma.socket`
```ini
[Unit]
Description=DiffusionGemma socket (on-demand activation)
[Socket]
ListenStream=0.0.0.0:11435
[Install]
WantedBy=sockets.target
```
With socket activation the service is enabled but not running; the first TCP connection to `:11435` triggers `diffusiongemma.service`. Combine with an `ExecStartPre` that unloads Ollama first (below). VRAM is 0 until someone actually hits the diffusion endpoint.

### 2c. Unload-the-other on start

Add to `diffusiongemma.service`:
```ini
ExecStartPre=/usr/local/bin/free-gpu-for diffusion
```
`/usr/local/bin/free-gpu-for` unloads Ollama models and waits for `nvidia-smi` to confirm free VRAM before the Python process is allowed to touch CUDA. Symmetrically, an Ollama request path should ensure diffusion is stopped (harder to hook cleanly inside ollama.service — this is what the arbiter/proxy solves in the fuller version).

---

## 3. Arbiter / supervisor design

Three viable designs, increasing complexity:

### Design A — Explicit switch CLI (recommended MVP)
User (or a devcontainer script) runs `gpu-switch diffusion` or `gpu-switch ollama`. No request interception. The person knows which mode they're in.

```
gpu-switch <target>:
  target == diffusion:
      unload_ollama()                 # ollama stop for each model in /api/ps
      wait_vram_free(threshold)       # nvidia-smi poll, timeout -> abort
      systemctl start diffusiongemma
      wait_health(:11435/healthz)
  target == ollama:
      systemctl stop diffusiongemma   # SIGINT, wait for process exit
      wait_vram_free(threshold)
      # ollama loads lazily on next request; optional warm-up:
      curl :11434/api/generate -d '{"model":"<m>","keep_alive":"5m","prompt":""}'
```

### Design B — Socket activation + ExecStartPre (recommended MVP+)
Design A's `unload_ollama` logic lives in `ExecStartPre=/usr/local/bin/free-gpu-for diffusion`, and diffusion starts automatically on first connection to `:11435` (§2b). The only missing symmetric piece: when an Ollama request arrives, diffusion must be stopped. For a single user this is acceptable to do manually (`gpu-switch ollama`) or via an Ollama-side wrapper.

### Design C — Request-routing arbiter (fuller version)
A small daemon (or nginx/Traefik with an auth-request hook) fronts both endpoints. Each incoming request passes through a "mode gate":

```
STATE = {current: "none"|"ollama"|"diffusion", lock: mutex}

on_request(target_endpoint):
    with lock:                        # serialize all switches
        if STATE.current == target: 
            pass                      # already resident, fast path
        else:
            drain_and_unload(STATE.current)   # graceful: reject/queue new, wait in-flight
            wait_vram_free(threshold, timeout=90s)
            load(target)                       # start service / warm model
            wait_health(target)
            STATE.current = target
    proxy(request -> target)           # forward now that GPU is correct

drain_and_unload(mode):
    if mode == "ollama":     for m in ps(): ollama_stop(m)
    if mode == "diffusion":  systemctl stop diffusiongemma
    if mode == "none":       return

wait_vram_free(threshold, timeout):
    deadline = now + timeout
    while used_vram() > threshold:
        if now > deadline: raise SwitchTimeout   # -> 503 to client, do NOT load
        sleep(0.5)
```

Implement the gate as a FastAPI middleware in front of a reverse proxy, or as nginx `auth_request` → a `/gate?target=diffusion` endpoint that blocks until the switch completes (raise nginx proxy timeouts to cover cold loads).

### Latency implications
- **Warm (already resident):** normal inference latency.
- **Cold switch:** unload (~1-5s for driver reclaim) + **load 18GB weights**. Loading is dominated by disk→VRAM bandwidth: from page cache / NVMe (~3-5GB/s) roughly **5-20s**; from cold spinning disk or first HF read it can be **minutes**. Ollama GGUF cold loads are similar per GB. **Mark as uncertain / measure on your box** — depends on storage, quantization, and runtime init.
- Consequence: an implicit lazy-load proxy will make the *first* request after a switch take tens of seconds. Set generous client/proxy timeouts (>= 120s) and, ideally, return an immediate "switching, retry" for non-blocking clients.

---

## 4. Failure modes & mitigations

| Failure | Cause | Mitigation |
|---|---|---|
| **Both load → OOM** | Two switches race, or unload not confirmed before load | Single global **mutex** around every switch; **never load until `nvidia-smi` confirms VRAM free** (poll, don't trust `/api/ps` alone). `CUDA_VISIBLE_DEVICES` pinned to same GPU so accounting is accurate. |
| **Partial unload** | Ollama runner subprocess slow to exit; driver hasn't reclaimed | `wait_vram_free` with per-process check (`--query-compute-apps`); timeout → abort the switch and return 503, do not force-load. |
| **Request arrives mid-switch** | Client hits endpoint while GPU is transitioning | Serialize via mutex; queue or fast-fail with `503 Retry-After`. In-flight requests to the outgoing model must **drain** before unload. |
| **Unload targets wrong model name** | `keep_alive:0` with mismatched name is a no-op | Enumerate `/api/ps` and unload each loaded model by its exact name; verify with `nvidia-smi`. |
| **Diffusion crash leaves VRAM held** | Python process died without freeing | `systemctl stop` + kill leftover PID from `--query-compute-apps`; `Restart=no` so it doesn't respawn and re-grab VRAM during an Ollama window. |
| **`OLLAMA_KEEP_ALIVE` reloaded model** | 5-min timer expired mid-diffusion? No — but a *new* devcontainer request reloads Ollama | While in diffusion mode, either stop `ollama.service` or have the arbiter reject/hold Ollama requests. This is the core reason single-user explicit switching is simplest. |
| **Pinned model won't evict** | Someone set `keep_alive:-1` | Arbiter always uses explicit `ollama stop`, which unloads regardless; avoid `-1` globally. |
| **Env var ignored** | Set in shell not service | Set `OLLAMA_KEEP_ALIVE` via systemd `Environment=` + `daemon-reload` + restart. |

---

## 5. MVP vs fuller version

**MVP (do this):** Design A/B for a single-user box.
1. `diffusiongemma.service` (§2a) with `Type=notify`, `TimeoutStopSec=60`, `Restart=no`.
2. `/usr/local/bin/gpu-switch` and `/usr/local/bin/free-gpu-for` (bash) implementing: unload-other → `wait_vram_free` via `nvidia-smi` → start-target → health-check.
3. Optional socket activation (§2b) so diffusion is truly 0-VRAM until first hit.
4. Leave Ollama at default `OLLAMA_KEEP_ALIVE=5m`; the switch script force-unloads with `ollama stop`.

Total: ~60 lines of bash + two unit files. No proxy, no daemon, cannot double-load.

**Fuller version (later, if multi-client / hands-off needed):** Design C request-routing arbiter (FastAPI middleware or nginx `auth_request`) with a mutex, request draining, queue + `503 Retry-After`, and Prometheus counters for switch count / cold-load latency. Justified only when you can't tolerate running an explicit command.

### Reference `free-gpu-for` sketch
```bash
#!/usr/bin/env bash
set -euo pipefail
TARGET="$1"; GPU=0; THRESH_MIB=2000; TIMEOUT=90
free_mib(){ nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i "$GPU"; }
wait_free(){ local d=$((SECONDS+TIMEOUT)); while (( $(free_mib) > THRESH_MIB )); do
  (( SECONDS > d )) && { echo "VRAM not freed"; exit 1; }; sleep 0.5; done; }

case "$TARGET" in
  diffusion)
    for m in $(curl -s localhost:11434/api/ps | jq -r '.models[].name'); do ollama stop "$m"; done
    wait_free ;;
  ollama)
    systemctl stop diffusiongemma.service || true
    wait_free ;;
esac
```

---

## Uncertain / verify-on-box
- **Cold-load time for 18GB DiffusionGemma** (5-20s warm-cache vs minutes cold) — depends on storage/runtime; measure.
- **Driver VRAM reclaim latency after unload** — usually 1-5s but poll `nvidia-smi`, don't assume.
- Whether the diffusion runtime releases *all* VRAM on `SIGINT` vs needing an explicit `torch.cuda.empty_cache()` / process exit — assume **process exit** is required (hence stop the service, don't just idle it).

## Sources
- [Ollama FAQ (official)](https://docs.ollama.com/faq)
- [Ollama FAQ (readthedocs mirror)](https://ollama.readthedocs.io/en/faq/)
- [Ollama Memory Management — SumGuy's Ramblings](https://sumguy.com/ollama-memory-management/)
- [Ollama Keeps Reloading the Model? Fix VRAM Unloading (2026) — runaihome](https://www.runaihome.com/blog/ollama-model-keeps-reloading-vram-fix-2026/)
- [keep_alive parameter — Instagit](https://instagit.com/ollama/ollama/what-keep-alive-parameter-affect-model-memory-usage/)
- [Configure Ollama Keep-Alive — Markaicode](https://markaicode.com/ollama-keep-alive-memory-management/)
- [Unloading Ollama Models Instantly — Paul Easterbrooks](https://pauleasterbrooks.com/articles/technology/clearing-ollama-memory)
- [Ollama Environment Variables Reference — ModelPiper](https://modelpiper.com/blog/ollama-environment-variables)
