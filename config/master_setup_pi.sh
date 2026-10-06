#!/bin/bash
# Master Setup Script for Pi Agent
# Managed by llm-sync
# v3.5.0: Environment-aware hosts — a provider's _defaultHost is written for the
#         Linux docker bridge; detect_agent_env picks how *this* agent reaches it
#         (bridge / host.docker.internal / localhost), and resolve_provider_url
#         normalises env values (0.0.0.0 bind address, bare host:port, no scheme).
# v3.2.0: Data-driven provider seam — each config/providers/*.json declares its
#         own _hostEnv/_defaultHost; the renderer rewrites baseUrl generically,
#         so a non-Ollama backend (HF/vLLM) needs only its own file, no code edit.
# v3.1.0: Model lists live in config/providers/*.json (one file per provider);
#         agentic/tool-capable models only; reasoning-only models removed.

# Where is this agent, network-wise, relative to the box serving the models?
#   devcontainer    Linux docker container  → the docker bridge (_defaultHost as written)
#   docker-desktop  Docker Desktop (Mac, WSL2) / OrbStack → host.docker.internal
#                   (no 172.17.0.1 to the real host from inside their VM)
#   podman          podman container (rootless or rootful) → host.containers.internal
#   host            bare shell, Linux or Mac → localhost
# LLM_AGENT_ENV forces one. Colima and friends look like a Linux devcontainer
# from inside, so set LLM_AGENT_ENV=docker-desktop there.
# LLM_DETECT_ROOT / LLM_DETECT_KERNEL exist only so tests can fake a container.
detect_agent_env() {
    if [[ -n "${LLM_AGENT_ENV:-}" ]]; then echo "$LLM_AGENT_ENV"; return 0; fi
    local root="${LLM_DETECT_ROOT:-}"
    if [[ -e "$root/run/.containerenv" ]]; then
        # podman writes this into every container; its host alias works rootless too
        echo podman
    elif [[ -e "$root/.dockerenv" || -n "${REMOTE_CONTAINERS:-}" ]]; then
        # Docker Desktop (Mac: linuxkit, Windows: the WSL2 kernel) and OrbStack
        # run containers in their own Linux VM; the kernel release gives it away.
        case "${LLM_DETECT_KERNEL:-$(uname -r)}" in
            *linuxkit*|*orbstack*|*microsoft*|*WSL2*) echo docker-desktop ;;
            *)                                         echo devcontainer ;;
        esac
    else
        echo host
    fi
}

# resolve_provider_url VALUE DEFAULT_HOST AGENT_ENV → the base URL (no /v1).
# VALUE is what the provider's _hostEnv var holds (may be empty). Ollama's own
# OLLAMA_HOST doubles as a server bind address — on my box it's 0.0.0.0 — so a
# bind-all host, a bare host:port, or a missing scheme/port are all made into
# something a client can actually connect to.
resolve_provider_url() {
    local raw="$1" def="$2" env="$3"
    local def_hp="${def#*://}"; def_hp="${def_hp%%/*}"
    local def_port="" target url scheme=http hp path="" h p="" bare=1
    case "$def_hp" in *:*) def_port="${def_hp##*:}" ;; esac
    case "$env" in
        host)           target=localhost ;;
        docker-desktop) target=host.docker.internal ;;
        podman)         target=host.containers.internal ;;
        *)              target="${def_hp%:*}" ;;
    esac

    url="${raw:-$def}"
    url="${url// /}"; url="${url%/}"; url="${url%/v1}"; url="${url%/}"
    case "$raw" in *://*) bare="" ;; esac
    case "$url" in *://*) scheme="${url%%://*}"; url="${url#*://}" ;; esac
    hp="${url%%/*}"
    [[ "$url" == */* ]] && path="/${url#*/}"
    case "$hp" in
        "::"|"[::]") h="" ;;
        \[*\]:*)   h="${hp%:*}"; p="${hp##*:}" ;;
        \[*\])     h="$hp" ;;
        *:*:*)     h="[$hp]" ;;   # bare IPv6 (::1) — no port can follow unbracketed
        *:*)       h="${hp%:*}"; p="${hp##*:}" ;;
        *)         h="$hp" ;;
    esac
    # No explicit value: the default's host is the bridge, which only a Linux
    # container can reach — swap in this environment's host, keep the port.
    [[ -z "$raw" ]] && h="$target"
    case "$h" in ""|0.0.0.0|"[::]") h="$target" ;; esac
    # Only a schemeless value gets the default's port. An explicit http://host
    # means port 80, as it does to Ollama's own client (and did here pre-3.5).
    [[ -z "$p" && -n "$bare" ]] && p="$def_port"
    echo "$scheme://$h${p:+:$p}$path"
}

# Render all per-provider model files into Pi's single models.json document.
# Keep this function before the source guard so verification can invoke the
# installer's exact transform without running the rest of the installer.
render_pi_models() {
    local providers_dir="$1"
    local output_file="$2"
    local provider_file provider_name host_env default_host value
    local agent_env="${LLM_AGENT_ENV:-devcontainer}"
    local base_urls='{}'
    local provider_files=("$providers_dir"/*.json)

    # Data-driven baseUrl rewrite: each provider file declares its own
    # `_hostEnv` (env var that overrides the host) and `_defaultHost`. The
    # host is resolved per environment and `/v1` appended — no provider name
    # is special-cased here, so a new backend (HF/vLLM diffusion, etc.) needs
    # only its own JSON file, never a renderer edit. The environment comes from
    # LLM_AGENT_ENV (set by the entrypoints via detect_agent_env); unset means
    # devcontainer, the historical behaviour the golden fixture locks.
    for provider_file in "${provider_files[@]}"; do
        provider_name="$(jq -r '
            .providers | keys_unsorted
            | if length == 1 then .[0] else empty end
        ' "$provider_file")" || return 1
        host_env="$(jq -r '._hostEnv // empty' "$provider_file")" || return 1
        default_host="$(jq -r '._defaultHost // empty' "$provider_file")" || return 1

        # A provider without _hostEnv keeps its file baseUrl verbatim.
        [[ -n "$provider_name" && -n "$default_host" ]] || continue
        value=""
        [[ -n "$host_env" ]] && value="${!host_env:-}"
        base_urls="$(jq -cn \
            --argjson current "$base_urls" \
            --arg provider "$provider_name" \
            --arg base "$(resolve_provider_url "$value" "$default_host" "$agent_env")/v1" \
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
    # Usually a Linux devcontainer → bridge addresses; Docker Desktop on a Mac
    # or a bare host get their own (see detect_agent_env).
    LLM_AGENT_ENV="$(detect_agent_env)"
    export LLM_AGENT_ENV
    render_pi_models "$PROVIDERS_DIR" ~/.pi/agent/models.json
    echo "✅ Pi Agent configured per provider (agentic-only, env: $LLM_AGENT_ENV):"
    jq -r '.providers | to_entries[] | "   \(.key) → \(.value.baseUrl)"' ~/.pi/agent/models.json
fi
