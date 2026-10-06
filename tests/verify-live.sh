#!/usr/bin/env bash
# Run ON the workstation. Confirms the running system matches the repo — i.e. you
# didn't hand-edit something live that never made it back into git. CI can't check
# this (no GPU, no venv, no ~/.pi); this is the local half of "no drift".
#
#   tests/verify-live.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 1. The agent's live config matches a fresh render from the repo's providers.
LIVE_MODELS="$HOME/.pi/agent/models.json"
if [[ -f "$LIVE_MODELS" ]]; then
  # Render for wherever this shell is — what llm-agent-config would write here.
  FRESH="$(mktemp)"; ( source "$REPO/config/master_setup_pi.sh" && LLM_AGENT_ENV="$(detect_agent_env)" \
                       && export LLM_AGENT_ENV && render_pi_models "$REPO/config/providers" "$FRESH" )
  # compare normalized (order-insensitive) JSON
  if diff -q <(jq -S . "$LIVE_MODELS") <(jq -S . "$FRESH") >/dev/null 2>&1; then
    _ok "~/.pi/agent/models.json matches a fresh render (no drift)"
  else
    _fail "~/.pi/agent/models.json differs from a fresh render" \
          "re-run: llm-agent-config   (or, in a devcontainer, re-provision so setup_pi.sh renders it)"
  fi
  rm -f "$FRESH"
else
  echo "  skip - no ~/.pi/agent/models.json (agent not configured on this host)"
fi

# 2. The bin/ tools on PATH point back into THIS repo (not a stale copy elsewhere).
for name in gpu-switch llm-manage llm-status llm-sync llm-agent-config; do
  live="$(command -v "$name" 2>/dev/null)"
  if [[ -z "$live" ]]; then echo "  skip - $name not on PATH"; continue; fi
  eq "$name on PATH resolves into this repo" "$REPO/bin/$name" "$(resolve_link "$live")"
done

# 3. The diffusion venv matches the shipped lockfile (bit-for-bit reproducible server).
VENV="${DIFFUSION_VENV:-/data1/venvs/diffusion}"
LOCK="$REPO/serving/diffusion/requirements.lock.txt"
if [[ -x "$VENV/bin/pip" ]]; then
  if diff -q <("$VENV/bin/pip" freeze 2>/dev/null | sort) <(sort "$LOCK") >/dev/null 2>&1; then
    _ok "diffusion venv matches serving/diffusion/requirements.lock.txt"
  else
    _fail "diffusion venv differs from the lockfile" \
          "refresh: $VENV/bin/pip freeze | sort > $LOCK   (then commit)"
  fi
else
  echo "  skip - no venv at $VENV (diffusion server not built here)"
fi

# 4. The systemd unit's ExecStart venv path actually exists.
UNIT="$REPO/systemd/diffusiongemma.service"
execpath="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$UNIT" 2>/dev/null | head -1)"
if [[ -n "$execpath" ]]; then
  if [[ -x "$execpath" ]]; then _ok "unit ExecStart binary exists ($execpath)"
  else _fail "unit ExecStart binary missing: $execpath" "build it: serving/diffusion/build-venv.sh"; fi
fi

finish
