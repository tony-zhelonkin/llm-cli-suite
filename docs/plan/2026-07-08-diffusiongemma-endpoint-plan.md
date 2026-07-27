# Plan — DiffusionGemma as a non-Ollama endpoint

**Goal.** Serve `google/diffusiongemma-26B-A4B-it` (true diffusion decoding) behind the same
OpenAI `/v1` seam the fleet already speaks, as a **separate provider** — without touching the
agentic-only Ollama single-source-of-truth. Decisions already locked: **vLLM native runtime**
(pending verification), **on-demand single-GPU mux**, **`config/providers/` directory refactor**.

Full research + rationale: `docs/agent-research/2026-07-08-diffusiongemma-serving/`.

---

## Step 0 — Verification gate (do first; everything depends on it)

Nothing below gets built until this closes. All model-specific findings are post-cutoff and
web-sourced (flagged UNVERIFIED in the research).

- [ ] Confirm against the **live HF repo + vLLM docs** that vLLM serves *this exact model* today.
- [ ] Capture the exact launch flags for the diffusion sampling profile
      (`--hf-overrides` / `--diffusion-config`, denoise steps, temp schedule, entropy bounds).
- [ ] Confirm whether the Pi agent's **tool-calling survives diffusion decoding** (and pseudo-streaming).
- **If vLLM native does NOT hold** → fall back to the FastAPI shim in research artifact 03.

## Step 1 — Stand up the serving layer (host, manual)

- [ ] `vllm serve google/diffusiongemma-26B-A4B-it` with the verified diffusion flags, bound to
      `0.0.0.0:11435`, quantized to fit ~18GB.
- [ ] Smoke test: `curl :11435/v1/chat/completions` and `/v1/models`.
- [ ] `ufw allow 11435/tcp comment 'DiffusionGemma /v1 (Docker bridge)'` (mirror the Ollama rule).
- **Exit criteria:** an OpenAI request over the bridge (`172.17.0.1:11435`) returns a completion.

## Step 2 — On-demand single-GPU mux (MVP)

Per research artifact 04 — the simplest thing that can never double-load the GPU.

- [ ] `gpu-switch` CLI: `gpu-switch ollama` | `gpu-switch diffusion` — mutex-guarded.
- [ ] Free Ollama VRAM via `ollama stop` / `keep_alive:0`, then **verify freed via `nvidia-smi`**
      (never trust the API alone — keep_alive:0 no-ops unless it names the loaded model).
- [ ] `Type=notify` systemd unit for the vLLM diffusion server (start/stop = load/unload).
- **Defer** the auto-routing proxy (Design C) — explicit switch is the MVP.
- **Exit criteria:** switching directions leaves exactly one server resident, confirmed by `nvidia-smi`.

## Step 3 — Config: `providers/` refactor + `diffusion` provider

- [ ] Refactor `config/models.agentic.json` → `config/providers/ollama.agentic.json` (unchanged
      content, own file). Installer loops over `providers/*.json` instead of hardcoding `ollama`.
- [ ] Add `config/providers/diffusion.json`: own policy header, models list, `baseUrl` rewritten
      from a new `DIFFUSION_HOST` env var (parallel to `OLLAMA_HOST`), port 11435.
- [ ] Update `config/master_setup_pi.sh` transform: per-provider `del(_doc)` + baseUrl rewrite +
      merge into `~/.pi/agent/models.json`.
- [ ] Mirror into scbio-docker `setup_ai_env.sh §1b` (same source files).
- **Invariant:** diffusion sampling knobs live ONLY in the vLLM launch flags — never in the JSON.
- **Exit criteria:** `~/.pi/agent/models.json` shows both `ollama` and `diffusion` providers;
      Pi lists both; `models.agentic.json`'s agentic-only invariant is untouched.

## Step 4 — Rollout

- [ ] `llm-sync` propagates the new `providers/` files to devcontainers.
- [ ] Add `DIFFUSION_HOST` to the relevant `devcontainer.json` `containerEnv` (only where wanted).
- [ ] Update `docs/devcontainer-ollama-passthrough.md` with the second-endpoint case.

---

## Later — ADRs to decide *after* testing

Deliberately deferred; these need real behavior data, not a priori guesses.

- **ADR-002 — vLLM native vs FastAPI shim.** Ratify once Step 0 verification is in. Record which
  runtime won and why (native support quality, streaming, flags).
- **ADR-003 — Is DiffusionGemma agentic or chat-only?** Depends on Step 0's tool-calling test.
  If tool-calling is unreliable under diffusion, keep it a separate non-agentic provider so it
  can't 400 the agent fleet — same reasoning that excludes reasoning-only models today.
- **ADR-004 — Mux: explicit switch vs auto-routing proxy.** Revisit after living with the
  `gpu-switch` MVP. Promote to a routing proxy only if manual switching proves too painful, or if
  a second GPU removes the constraint entirely.
- **ADR-005 — Gen 1 (`master_setup_pi.sh` / llm-sync) vs Gen 2 (`setup_ai_env.sh`) lineage.**
  Pre-existing overlap; the `providers/` refactor touches both. Decide which lineage retires so we
  don't maintain two installers writing the same config.

---

**State at end of 2026-07-08:** research complete and inventoried; no serving code, no config
changes, nothing pulled beyond the (fake) `drmdltd` blob still on the host — `ollama rm
drmdltd/diffusiongemma-26B-A4B-it-bucket` when convenient. Resume at Step 0.
