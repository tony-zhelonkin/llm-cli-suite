#!/usr/bin/env bash
# The renderer is the crown jewel — a bug here breaks every devcontainer's model
# config. These tests lock its behaviour so GitHub can never drift from it.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
render() { ( unset OLLAMA_HOST DIFFUSION_HOST; source "$REPO/config/master_setup_pi.sh" && render_pi_models "$@"; ); }

# --- NO-OP gate: ollama-only render must equal the committed golden, byte for byte ---
cp "$REPO/config/providers/ollama.agentic.json" "$TMP/ollama.agentic.json"
render "$TMP" "$TMP/out.json"
ok   "ollama-only render matches golden (NO-OP gate)" \
     diff -q "$REPO/tests/golden/models.ollama-only.json" "$TMP/out.json"

# --- private fields are stripped from the output ---
eq  "_comment stripped"     "null" "$(jq -r '.providers.ollama._comment // "null"' "$TMP/out.json")"
eq  "_hostEnv stripped"     "null" "$(jq -r '._hostEnv // "null"' "$TMP/out.json")"
eq  "_defaultHost stripped" "null" "$(jq -r '._defaultHost // "null"' "$TMP/out.json")"

# --- env override rewrites the host, generically (no name special-casing) ---
OUT="$( ( unset DIFFUSION_HOST; export OLLAMA_HOST=http://10.9.8.7:11434; source "$REPO/config/master_setup_pi.sh" && render_pi_models "$TMP" /dev/stdout ) )"
eq  "OLLAMA_HOST override applied" "http://10.9.8.7:11434/v1" "$(jq -r '.providers.ollama.baseUrl' <<<"$OUT")"

# --- a second provider drops in with no renderer change, keyed on its own env ---
cat > "$TMP/diffusion.json" <<'JSON'
{ "_hostEnv": "DIFFUSION_HOST", "_defaultHost": "http://172.17.0.1:11435",
  "providers": { "diffusion": { "baseUrl": "http://172.17.0.1:11435/v1", "models": [ {"id":"x","name":"X","contextWindow":128} ] } } }
JSON
OUT2="$( ( unset OLLAMA_HOST; export DIFFUSION_HOST=http://192.168.1.5:11435; source "$REPO/config/master_setup_pi.sh" && render_pi_models "$TMP" /dev/stdout ) )"
eq  "two providers merged"          "2" "$(jq -r '.providers | keys | length' <<<"$OUT2")"
eq  "diffusion host from its own env" "http://192.168.1.5:11435/v1" "$(jq -r '.providers.diffusion.baseUrl' <<<"$OUT2")"
eq  "ollama untouched by 2nd provider" "http://172.17.0.1:11434/v1" "$(jq -r '.providers.ollama.baseUrl' <<<"$OUT2")"

# --- output is always valid JSON ---
ok  "render output is valid JSON" jq -e . "$TMP/out.json"

finish
