#!/bin/bash
# Master Setup Script for Pi Agent
# Managed by llm-sync
# v2.2.1: Fixed bash syntax escaping error

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

# 3. Configure Models (Agentic only)
echo "Configuring Pi Agent models (Tool-Capable Only)..."
mkdir -p ~/.pi/agent/

cat << 'JSON' > ~/.pi/agent/models.json
{
  "providers": {
    "ollama": {
      "baseUrl": "http://172.17.0.1:11434/v1",
      "api": "openai-completions",
      "apiKey": "ollama",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        { "id": "batiai/qwen3.6-27b:iq4", "name": "Qwen 3.6 27B Dense (Primary Agent)", "reasoning": false, "contextWindow": 131072 },
        { "id": "qwen3.6:35b", "name": "Qwen 3.6 35B MoE (Fast Agent)", "reasoning": false, "contextWindow": 32768 },
        { "id": "gemma4:31b", "name": "Gemma 4 31B Dense (Multimodal Agent)", "reasoning": false, "contextWindow": 32768 }
      ]
    }
  }
}
JSON

echo "✅ Pi Agent Configured with Agentic (Tool-Capable) Models."
