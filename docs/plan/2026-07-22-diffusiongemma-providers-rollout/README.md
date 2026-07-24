---
date: 2026-07-22
subject: Phased, bite-sized rollout — DiffusionGemma as a second (non-Ollama) /v1 provider
status: active — Phase 1 delegated to codex
supersedes-scope-of: docs/plan/2026-07-08-diffusiongemma-endpoint-plan.md
related:
  - docs/agent-research/2026-07-08-diffusiongemma-serving/README.md   # verification log 2026-07-22
implementer: codex (OpenAI gpt-5.6-sol) via delegate-cli
---

# DiffusionGemma second-provider rollout — bite-sized phased plan

**Why this doc.** The 2026-07-08 plan was one big lump gated on a verification step. Step 0 is now
**closed** (see the research README verification log 2026-07-22): the model is real, vLLM native
serving + tool-calling are confirmed, **no shim needed**, and the one correction is VRAM
(FP8 ≈ 28GB, *not* ~18GB → the single-GPU mux may be unnecessary or impossible on a 24GB card).

This plan breaks the work into **independently testable phases**. Each phase has an explicit
**blast radius**, a **do**, and an **exit test**. We launch implementation **one phase at a time**,
verify the exit test in a clean/dedicated way, then proceed. Station is single-user (Anton only) —
we can restart services freely, but the fleet config is still the crown jewel.

## Blast-radius map (whole rollout, at a glance)

| Phase | Touches | Blast radius | Reversible? |
|---|---|---|---|
| 0 | nothing (measurement) | none | n/a |
| 1 | `config/`, `master_setup_pi.sh`, `llm-sync` | **fleet config renderer** (highest — a bug here breaks *all* devcontainers) | yes (git) |
| 2 | `systemd/`, host vLLM | one new service + GPU at serve time | yes (stop unit) |
| 3 | `bin/gpu-switch`, systemd | GPU residency / Ollama traffic | yes |
| 4 | `providers/diffusion.json`, docs, devcontainers | opt-in per container | yes |

**Golden rule:** Phase 1 must be a **behavioral no-op** — the rendered `~/.pi/agent/models.json`
is byte-identical to today's for the Ollama-only case. We prove that before anything diffusion-y
lands. Config-plumbing bugs and GPU-mux bugs never share a phase.

---

## Phase 0 — VRAM measurement gate (manual, on-box) — BLOCKING for Phases 2/3

- **Do:** pull `nvidia/diffusiongemma-26B-A4B-it-NVFP4` (or FP8), `vllm serve` it once by hand,
  read resident VRAM from `nvidia-smi`.
- **Exit test:** a single number. If NVFP4 < ~22GB resident → mux against Ollama on the 24GB card is
  viable (Phase 3 needed). If ≥ card size → either it needs the ≥40GB GPU (no mux; run alongside) or
  it's shelved. **Phases 2/3 do not start until this number exists.**
- Independent of Phase 1 — Phase 1 can proceed in parallel since it's Ollama-only plumbing.

## Phase 1 — `providers/` refactor as a NO-OP  ← **implement first**

- **Do:**
  1. `git mv config/models.agentic.json config/providers/ollama.agentic.json` (content unchanged).
  2. `master_setup_pi.sh`: replace the hardcoded `.providers.ollama.baseUrl` rewrite with a loop
     over `config/providers/*.json`, per-provider baseUrl rewrite, merged into one
     `~/.pi/agent/models.json`. Ollama's rewrite keyed on `OLLAMA_HOST` exactly as today.
  3. `llm-sync`: ship the `config/providers/` dir (all `*.json`) next to the installer instead of the
     single file.
- **Blast radius:** the fleet renderer. Highest of the whole rollout.
- **Exit test (clean/dedicated):** run the installer transform against the new layout and `diff` the
  produced `models.json` against the pre-refactor output — **must be byte-identical** (Ollama-only).
  No devcontainer rebuilt until the diff is clean.

## Phase 2 — Stand up the vLLM diffusion server (host, systemd)  ← gated on Phase 0

- **Do:** `Type=notify` unit running `vllm serve` (verified flags from research: `gemma` image,
  `VLLM_USE_V2_MODEL_RUNNER=1`, `--enable-auto-tool-choice --tool-call-parser gemma4
  --reasoning-parser gemma4`, `--hf-overrides`/`--diffusion-config`, `--max-num-seqs 4`) on `:11435`.
  `ufw allow 11435/tcp`.
- **Blast radius:** one isolated service; GPU only while serving.
- **Exit test:** `curl :11435/v1/models` and a `/v1/chat/completions` tool-call smoke test return OK.

## Phase 3 — GPU mux (`gpu-switch`)  ← **only if Phase 0 says VRAM-constrained**

- **Do:** generalized `gpu-switch <ollama|diffusion>` — mutex, `ollama stop` + `nvidia-smi`-confirmed
  free, then start target unit. (Design A/B from research artifact 04.)
- **Blast radius:** GPU residency + in-flight Ollama requests. Single-user, so tolerable.
- **Exit test:** switching either direction leaves exactly one server resident per `nvidia-smi`;
  cannot double-load.

## Phase 4 — Register diffusion provider + rollout

- **Do:** `config/providers/diffusion.json` (own policy header, `agentic` flag TBD by ADR-003,
  `baseUrl` from `DIFFUSION_HOST`, port 11435); `llm-sync` propagates; add `DIFFUSION_HOST` to
  chosen devcontainers; update `docs/devcontainer-ollama-passthrough.md`.
- **Exit test:** `~/.pi/agent/models.json` shows both providers; Pi lists both; agentic-only Ollama
  invariant untouched.

---

## Deferred ADRs (decide after live behavior)
- ADR-002 vLLM vs shim → **vLLM wins** (Step 0). Ratify + retire shim to fallback.
- ADR-003 diffusion agentic vs chat-only → leaning agentic (tool-calling confirmed); smoke-test first.
- ADR-004 explicit switch vs routing proxy → after living with `gpu-switch`.
- ADR-005 Gen1 (`master_setup_pi.sh`) vs Gen2 (`setup_ai_env.sh`) lineage → mirror or retire one.
