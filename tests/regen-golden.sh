#!/usr/bin/env bash
# Regenerate the renderer golden fixture from the current providers. Run this
# (and commit the result) whenever you intentionally change the renderer or the
# ollama provider file. CI fails if the committed golden is stale vs a fresh render.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp "$REPO/config/providers/ollama.agentic.json" "$tmp/"
( unset OLLAMA_HOST DIFFUSION_HOST
  source "$REPO/config/master_setup_pi.sh"
  render_pi_models "$tmp" "$REPO/tests/golden/models.ollama-only.json" )
echo "regenerated tests/golden/models.ollama-only.json — review the diff and commit."
