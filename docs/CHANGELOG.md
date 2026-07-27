# Changelog

### 3.3.0 — 2026-07-26 (DiffusionGemma as a second provider — experimental)

**Wires the verified FP8 DiffusionGemma endpoint into the suite so Pi can use it.** Rides the 3.2.0
data-driven seam — no renderer change. GPU tenancy is exclusive (FP8 ~31GB won't share the 32GB
card with Ollama), so a mutex ships alongside.

- `config/providers/diffusion.json` — registers `RedHatAI/diffusiongemma-26B-A4B-it-FP8-dynamic`
  on `:11435`, keyed on `DIFFUSION_HOST`. Marked EXPERIMENTAL (8k ctx). llm-sync already ships it;
  the renderer merges it automatically (Ollama render verified unchanged).
- `systemd/diffusiongemma.service` — the exact Phase 0 `vllm serve` command as a host unit. Not
  enabled by default (must not autostart and steal the GPU). Uses the `+cu129` venv.
- `bin/gpu-switch {ollama|diffusion|off|status}` — the GPU mutex: stops the other tenant, waits for
  the card to drain, starts the target. Seed of the rollout's Phase 3.
- `docs/diffusiongemma-testing.md` — end-to-end runbook (install unit, ufw bridge rule, gpu-switch,
  point Pi at it) + what to / not to conclude from the constrained FP8 config.
- Backed by `docs/agent-research/2026-07-26-diffusiongemma-cuda12-compat/` (compat research +
  MEASUREMENT_phase0.md + venv freeze).

### 3.2.0 — 2026-07-26 (data-driven provider seam)

**The renderer no longer special-cases Ollama.** Phase 1 (3.1.0) split the model list into
`config/providers/*.json` but the baseUrl rewrite still hardcoded a `case ollama)`. Now each
provider file declares its own `_hostEnv` (env var that overrides the host) and `_defaultHost`;
`render_pi_models()` resolves the host by indirect expansion and appends `/v1` — no provider name
is special-cased. A non-Ollama backend (HF / vLLM diffusion endpoint) drops in as its own JSON
file with **zero renderer edits**. This is the clean architectural seam the second-provider
rollout needed.

- `config/providers/ollama.agentic.json` — adds `_hostEnv: "OLLAMA_HOST"` + `_defaultHost`.
- `config/master_setup_pi.sh` (v3.2.0) — generic per-provider host rewrite; both private fields
  stripped from the rendered output.
- Verified: Ollama-only render is **byte-identical** to 3.1.0 (NO-OP gate); a two-provider render
  (temp `diffusion.json`) rewrites each host from its own env var with no code change.

### 3.1.0 — 2026-07-22 (per-provider model lists)

**`config/models.agentic.json` → `config/providers/*.json` (one file per provider).**
The single agentic list became a directory keyed by provider, so a non-Ollama backend (e.g. a
vLLM diffusion endpoint) can be added as its own file without touching the installer. Behavioural
no-op for the existing Ollama set — verified byte-identical output.

- `config/providers/ollama.agentic.json` — the former `models.agentic.json`, unchanged content.
- `config/master_setup_pi.sh` (v3.1.0) — `render_pi_models()` loops `providers/*.json` and keys
  the per-provider `baseUrl` rewrite on env (`OLLAMA_HOST`); a `BASH_SOURCE` guard lets a verifier
  source the exact transform.
- `bin/llm-sync` — ships the whole `providers/` dir next to the installer.
- `docs/plan/2026-07-22-diffusiongemma-providers-rollout/` — phased rollout plan (Phase 1 = this).

### 3.0.0 — 2026-07-07 (single source of truth + agentic-only + docs)

**Model list: one source of truth, agentic-only.**
The Pi model list used to live in three drifting copies (host `~/.pi/agent/models.json`,
`master_setup_pi.sh`'s heredoc, and scbio-docker's `configure_pi_models.sh`). It is now a single
file — `config/models.agentic.json` — that the installers read and transform. Only agentic
(tool-capable) models are listed. The reasoning-only models (FuseO1, DeepSeek-R1) were removed:
Pi tries to tool-call them and gets a 400, so they never belonged in an agent's list. They remain
useful for Continue/chat, which is where they live now.

- `config/models.agentic.json` — new canonical list (agentic-only).
- `config/master_setup_pi.sh` (v3.0.0) — no more inline model heredoc; reads the adjacent
  `models.agentic.json`, strips the doc fields, and rewrites the Ollama `baseUrl` to the
  container's `OLLAMA_HOST`.
- `bin/llm-sync` — now ships `models.agentic.json` next to `setup_pi.sh` into every devcontainer,
  and excludes `*/.ref/*` paths from discovery.
- scbio-docker — the orphan `configure_pi_models.sh` (a second model list, referenced by nothing)
  was deleted; its job folded into the single `setup_ai_env.sh` (section 1b), which reads the same
  `models.agentic.json`. This is the "one script manages AI in the devcontainer" consolidation.

**480B "Titan" retired.**
Even tamed (weights resident, context clamped to 8192 to survive), `qwen3-coder:480b` ran at
2–5 t/s out of system RAM after a 20-30-minute cold start, and the clamp killed its only advantage.
The 27–35B tier — fully in the 32GB card with a real 128k window via `q8_0` KV cache — wins in
practice. The toolkit's posture is now single-model : single-GPU residency on that tier.

**Shipped tuning as version-controlled artifacts (with READMEs).**
- `systemd/ollama.override.conf` — the global layer: `q8_0` KV-cache quantization + flash
  attention + storage/host/keep-alive. See `docs/ollama-tuning.md`.
- `modelfiles/*.mf` — the per-model layer: baked `num_ctx 131072` + tuned samplers. See
  `docs/modelfile-surgery.md`. (This is the part I'd forgotten I did — Modelfile surgery, not
  just the central KV setting.)

**New docs.**
- `docs/ollama-tuning.md` — global tuning layer (systemd).
- `docs/modelfile-surgery.md` — per-model tuning layer (Modelfiles).
- `docs/devcontainer-ollama-passthrough.md` — how to make Pi in a container reach the host Ollama
  over the `172.17.0.1` bridge, including the postStartCommand wiring that is easy to miss.

### History (from git, for context)
- `269615c` setup agentic-only models for Pi
- `a0f8e9c` single-model : single-GPU residency architecture
- `5673466` remove npm prefix to prevent nvm conflict
- `41d4496` add qwen3.6 to pi config
- `79a9b74` setup_pi.sh auto-installs NVM/Node, fixes Pi PATH
- `c19006b` scope npm global installs to ~/.npm-global (EACCES)
- `5878e57` graceful fallback + nvm sourcing when npm missing
- `98fa55b` race conditions, install paths, security/hardware docs
- `cb56297` README, MIT license, architecture + memory-physics docs
- `075d0e3` initial commit: local llm management and monitoring tools
