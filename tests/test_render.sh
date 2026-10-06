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

# --- host resolution per environment (the defaults are written for the Linux bridge) ---
url() { ( source "$REPO/config/master_setup_pi.sh" && resolve_provider_url "$@" ); }
D=http://172.17.0.1:11434
eq  "devcontainer keeps the bridge default"     "http://172.17.0.1:11434"           "$(url "" $D devcontainer)"
eq  "bare host → localhost"                     "http://localhost:11434"            "$(url "" $D host)"
eq  "Docker Desktop → host.docker.internal"     "http://host.docker.internal:11434" "$(url "" $D docker-desktop)"
# OLLAMA_HOST=0.0.0.0 is the server's bind address on my box, not somewhere to connect
eq  "0.0.0.0 on the host → localhost"           "http://localhost:11434"            "$(url 0.0.0.0 $D host)"
eq  "0.0.0.0 in a devcontainer → bridge"        "http://172.17.0.1:11434"           "$(url 0.0.0.0 $D devcontainer)"
eq  "0.0.0.0:port in Docker Desktop"            "http://host.docker.internal:11434" "$(url 0.0.0.0:11434 $D docker-desktop)"
eq  "[::]:port bind-all → localhost"            "http://localhost:11434"            "$(url '[::]:11434' $D host)"
eq  ":port alone → localhost"                   "http://localhost:11434"            "$(url :11434 $D host)"
eq  "bare host gets scheme + default port"      "http://gpubox:11434"               "$(url gpubox $D host)"
eq  "bare host:port gets a scheme"              "http://gpubox:9000"                "$(url gpubox:9000 $D host)"
eq  "explicit URL kept as-is"                   "http://10.9.8.7:11434"             "$(url http://10.9.8.7:11434 $D docker-desktop)"
eq  "https without port stays portless"         "https://llm.example.org"           "$(url https://llm.example.org $D host)"
eq  "trailing /v1/ trimmed (no /v1/v1)"         "http://localhost:11434"            "$(url http://localhost:11434/v1/ $D host)"
eq  "IPv6 loopback kept"                        "http://[::1]:11434"                "$(url '[::1]:11434' $D host)"

# the env flows through the whole render, for every provider, by its own port
OUT3="$( ( unset OLLAMA_HOST DIFFUSION_HOST; export LLM_AGENT_ENV=host; source "$REPO/config/master_setup_pi.sh" && render_pi_models "$TMP" /dev/stdout ) )"
eq  "host render: ollama on localhost"    "http://localhost:11434/v1" "$(jq -r '.providers.ollama.baseUrl' <<<"$OUT3")"
eq  "host render: diffusion on localhost" "http://localhost:11435/v1" "$(jq -r '.providers.diffusion.baseUrl' <<<"$OUT3")"
OUT4="$( ( unset DIFFUSION_HOST; export LLM_AGENT_ENV=host OLLAMA_HOST=0.0.0.0; source "$REPO/config/master_setup_pi.sh" && render_pi_models "$TMP" /dev/stdout ) )"
eq  "host render: bind-all OLLAMA_HOST normalised" "http://localhost:11434/v1" "$(jq -r '.providers.ollama.baseUrl' <<<"$OUT4")"

# --- environment detection (faked filesystem root + kernel) ---
# detect ROOT [KERNEL] — detection with a fake / and uname -r
detect() { ( unset LLM_AGENT_ENV REMOTE_CONTAINERS; export LLM_DETECT_ROOT="$1" LLM_DETECT_KERNEL="${2:-6.8.0-generic}"
             source "$REPO/config/master_setup_pi.sh"; detect_agent_env ); }
FAKEROOT="$TMP/root"; mkdir -p "$FAKEROOT"
eq  "no container markers → host" "host" "$(detect "$FAKEROOT")"
touch "$FAKEROOT/.dockerenv"
eq  "/.dockerenv on a stock kernel → devcontainer" "devcontainer" \
    "$(detect "$FAKEROOT" 6.8.0-136-generic)"
eq  "/.dockerenv on linuxkit → docker-desktop" "docker-desktop" \
    "$(detect "$FAKEROOT" 6.10.14-linuxkit)"
eq  "LLM_AGENT_ENV wins over detection" "host" \
    "$( ( source "$REPO/config/master_setup_pi.sh"; LLM_AGENT_ENV=host LLM_DETECT_ROOT="$FAKEROOT" detect_agent_env ) )"

# --- llm-agent-config: the client entrypoint writes models.json for its env ---
AH="$TMP/agenthome"; mkdir -p "$AH"
( unset OLLAMA_HOST DIFFUSION_HOST; HOME="$AH" LLM_AGENT_ENV=host "$REPO/bin/llm-agent-config" ) >/dev/null 2>&1
ok  "llm-agent-config writes ~/.pi/agent/models.json" test -s "$AH/.pi/agent/models.json"
eq  "llm-agent-config renders for the host" "http://localhost:11434/v1" \
    "$(jq -r '.providers.ollama.baseUrl' "$AH/.pi/agent/models.json" 2>/dev/null)"
eq  "llm-agent-config ships the whole roster" "$(ls "$REPO"/config/providers/*.json | wc -l | tr -d ' ')" \
    "$(jq -r '.providers | length' "$AH/.pi/agent/models.json" 2>/dev/null)"

# --- output is always valid JSON ---
ok  "render output is valid JSON" jq -e . "$TMP/out.json"

finish
