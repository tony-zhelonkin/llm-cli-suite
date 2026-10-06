# Changelog

### 3.5.0 — 2026-10-05 (macOS + an explicit server/client split)

**The suite runs on a Mac now, and the topology is written down.** The server half (Ollama + its
tuning, `llm-manage`, `llm-status`, the watchdog, `sys-notify`) runs on whatever box has the
accelerator. The client half (the provider roster + renderer) runs wherever an agent does. `gpu-switch` and the
diffusion vLLM unit stay Linux/NVIDIA-only and refuse cleanly elsewhere.

- **Environment-aware hosts.** `detect_agent_env` tells a Linux devcontainer (bridge `172.17.0.1`)
  from a Docker Desktop/OrbStack container (`host.docker.internal`) and a bare host (`localhost`).
  `resolve_provider_url` normalises `_hostEnv` values. `OLLAMA_HOST=0.0.0.0` is my server's bind
  address, so a bind-all host, a bare `host[:port]`, a missing scheme and a trailing `/v1` all become
  something connectable. Still data-driven: the host is swapped, the port kept, no provider named.
  The renderer takes `LLM_AGENT_ENV` (unset = devcontainer), so the golden fixture is
  **unchanged**.
- `bin/llm-agent-config` — the thin client entrypoint: renders `~/.pi/agent/models.json` for the
  current shell, no npm. `setup_pi.sh` in containers detects the same way, so existing Linux
  devcontainers render exactly as before.
- `lib/platform.sh` — OS, accelerator, RAM/VRAM probes; bash 3.2 / BSD-safe. `llm-status` derives
  its banners (no more hardcoded 512GB / RTX 5000 Ada), and on a Mac reads `hw.memsize` + `vm_stat`
  and shows the unified-memory note. `sys-ram-watchdog` only checks VRAM where `nvidia-smi` exists.
- `llm-manage` — the residency check is `/api/ps` after a blocking load. The old one used
  `/proc/$PID/VmRSS`, which doesn't exist on a Mac. Its `pgrep` matched the runner's cmdline, which
  holds a blob path, not the model name. And its `mktemp` template broke on BSD.
- `install.sh` — OS-aware, `set -euo pipefail`, idempotent, says what it skipped. On a Mac the
  watchdog is `launchd/com.tony.sys-ram-watchdog.plist`, loaded with `launchctl bootstrap`. The
  systemd unit uses `%h` instead of my home path. `launchd/com.tony.ollama-env.plist` is the Mac
  twin of the Ollama override (keep-alive `30m`, not `-1` — unified memory is shared).
- `llm-sync` — `LLM_SYNC_ROOTS` overrides the workspace roots.
- **One-time migration on the workstation:** run `llm-agent-config` after merging. The host's
  `~/.pi/agent/models.json` was rendered with the bridge (`172.17.0.1`). That still works on the
  host, but a bare host now resolves to `localhost`, so `make verify` reports drift until it's
  re-rendered. Devcontainers need nothing — they still render the bridge.
- Tests — host-resolution + detection cases, both install branches (`LLM_SUITE_OS` + stub
  `launchctl`/`systemctl`), platform probes against fake `sysctl`/`vm_stat`, `llm-sync` end to end,
  and a static lint for Linux-isms in mac-reachable code. CI gains a `macos-latest` job running the
  suite under stock `/bin/bash` 3.2.
- Docs — server/client diagram and the host-resolution tables in `architecture.md`, plus "Where this
  sits in the stack". That section notes the known drift in scbio-docker's own `models.agentic.json`
  and stale `configure_pi_models.sh` copies; those aren't fixed here. A Mac path in
  `getting-started.md`.

### 3.4.0 — 2026-07-26 (DiffusionGemma W4A16 — real 128k agent)

**The quant hunt succeeded: W4A16 int4 serves DiffusionGemma at 128k on the Ada card.** Desk
research (agy) concluded int4 was blocked for the diffusion runner on Ada; the empirical test
disproved it — vLLM 0.26 selects `MARLIN WNA16` for both linear and MoE layers and runs the
diffusion sampler on top. ~15GB weights (vs FP8's 26GB) leave ~13GB KV → 128k context (vs 14k).

- `config/providers/diffusion.json` — model → `pixelkaiser/diffusiongemma-26B-A4B-it-AWQ-MLP-W4A16`,
  `contextWindow` 131072, no longer 'experimental'.
- `systemd/diffusiongemma.service` — serves the W4A16 checkpoint at `--max-model-len 131072`.
  FP8 retained only as a higher-precision fallback (in docs).
- `docs/agent-research/2026-07-26-diffusiongemma-int4-quant-hunt/` — brief, agy report, RedHat
  model-card analysis, synthesis (with SUPERSEDED banner), and `MEASUREMENT_w4a16.md` (the win).
- Lesson recorded: verify negative claims empirically when the test is cheap.

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
  the card to drain, starts the target. Seed of the rollout's Phase 3. Every privileged command is
  echoed before it runs (via `run()`) — no invisible sudo.
- `docs/diffusiongemma-testing.md` — end-to-end runbook. Host setup (systemd unit + ufw) is written
  as **explicit, explained sudo commands you run yourself**, deliberately NOT wrapped in an
  installer script: privileged host mutations should be observable, not hidden behind an opaque
  verb. (A wrapper was tried and reverted — it obscured the sudo *and* had a symlink-path bug.)
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
