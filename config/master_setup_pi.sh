#!/bin/bash
# Master Setup Script for Pi Agent
# Managed by llm-sync
# v3.2.0: Data-driven provider seam — each config/providers/*.json declares its
#         own _hostEnv/_defaultHost; the renderer rewrites baseUrl generically,
#         so a non-Ollama backend (HF/vLLM) needs only its own file, no code edit.
# v3.1.0: Model lists live in config/providers/*.json (one file per provider);
#         agentic/tool-capable models only; reasoning-only models removed.

# Render all per-provider model files into Pi's single models.json document.
# Keep this function before the source guard so verification can invoke the
# installer's exact transform without running the rest of the installer.
render_pi_models() {
    local providers_dir="$1"
    local output_file="$2"
    local provider_file provider_name host_env default_host host
    local base_urls='{}'
    local provider_files=("$providers_dir"/*.json)

    # Data-driven baseUrl rewrite: each provider file declares its own
    # `_hostEnv` (env var that overrides the host) and `_defaultHost`. The
    # host is resolved per environment and `/v1` appended — no provider name
    # is special-cased here, so a new backend (HF/vLLM diffusion, etc.) needs
    # only its own JSON file, never a renderer edit.
    for provider_file in "${provider_files[@]}"; do
        provider_name="$(jq -r '
            .providers | keys_unsorted
            | if length == 1 then .[0] else empty end
        ' "$provider_file")" || return 1
        host_env="$(jq -r '._hostEnv // empty' "$provider_file")" || return 1
        default_host="$(jq -r '._defaultHost // empty' "$provider_file")" || return 1

        # A provider without _hostEnv keeps its file baseUrl verbatim.
        [[ -n "$provider_name" && -n "$default_host" ]] || continue
        host="${!host_env:-$default_host}"
        base_urls="$(jq -cn \
            --argjson current "$base_urls" \
            --arg provider "$provider_name" \
            --arg base "${host%/}/v1" \
            '$current + {($provider): $base}')" || return 1
    done

    jq --argjson base_urls "$base_urls" -s '
        map(
            del(._comment, ._policy, ._bridge, ._hostEnv, ._defaultHost)
            | .providers |= with_entries(
                if $base_urls[.key] != null
                then .value.baseUrl = $base_urls[.key]
                else .
                end
            )
        )
        | reduce .[] as $config ({"providers": {}}; .providers += $config.providers)
    ' "${provider_files[@]}" > "$output_file"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

echo "Installing Pi Coding Agent..."

# 1. Force environment to check for local NVM first
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Check if npm is available AND writable
NEED_LOCAL_NODE=false
if command -v npm &> /dev/null; then
    GLOBAL_ROOT=$(npm root -g)
    if [ ! -w "$GLOBAL_ROOT" ] && [ ! -w "$(dirname "$GLOBAL_ROOT")" ]; then
        echo "⚠️ Global npm root ($GLOBAL_ROOT) is restricted. Switching to local user-space Node..."
        NEED_LOCAL_NODE=true
    fi
else
    NEED_LOCAL_NODE=true
fi

if [ "$NEED_LOCAL_NODE" = "true" ]; then
    if [ ! -d "$NVM_DIR" ]; then
        echo "📦 Installing NVM and Node.js LTS in $HOME/.nvm..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        nvm install 20
        nvm use 20
        nvm alias default 20
    else
        echo "✅ Local NVM detected. Ensuring Node 20 is active..."
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        nvm use 20 || nvm install 20
    fi
fi

# 2. Install Pi Agent
echo "📥 Downloading @mariozechner/pi-coding-agent..."
npm install -g @mariozechner/pi-coding-agent

# 3. Configure Models (agentic / tool-capable only)
# The model lists are NOT hardcoded here. Their single source of truth is the
# adjacent providers/ directory, which llm-sync ships next to this script into
# every devcontainer. This installer transforms and merges them into Pi's config:
#   - strips each provider's leading _comment/_policy/_bridge doc fields
#   - rewrites each configured provider baseUrl for the container environment
# Reasoning-only models (FuseO1, DeepSeek-R1) are absent by policy — they do not
# tool-call. See docs/decisions notes folded into docs/CHANGELOG.md.
echo "Configuring Pi Agent models per provider (tool-capable only)..."
mkdir -p ~/.pi/agent/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$SCRIPT_DIR/providers"
PROVIDER_FILES=("$PROVIDERS_DIR"/*.json)

if [ ! -e "${PROVIDER_FILES[0]}" ]; then
    echo "⚠️  No provider JSON files found next to this script ($PROVIDERS_DIR)."
    echo "    Skipping Pi model config — run llm-sync to ship the provider lists."
elif ! command -v jq &> /dev/null; then
    echo "⚠️  jq not available; concatenating provider JSON verbatim (baseUrls not rewritten)."
    : > ~/.pi/agent/models.json
    for PROVIDER_FILE in "${PROVIDER_FILES[@]}"; do
        grep -v '"_' "$PROVIDER_FILE" >> ~/.pi/agent/models.json
    done
    echo "✅ Pi provider model lists written (verbatim)."
else
    # Container reaches host providers over their configured bridge addresses.
    BRIDGE="${OLLAMA_HOST:-http://172.17.0.1:11434}"
    render_pi_models "$PROVIDERS_DIR" ~/.pi/agent/models.json
    echo "✅ Pi Agent configured per provider (agentic-only) → Ollama @ ${BRIDGE}"
fi
