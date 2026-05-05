#!/bin/bash
# Master Setup Script for Pi Agent
# Managed by llm-sync

echo "Installing Pi Coding Agent..."

# Attempt to load NVM if it is installed in the devcontainer
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

if ! command -v npm &> /dev/null; then
    echo "📦 npm not found. Installing NVM and Node.js LTS automatically..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    
    # Load the newly installed NVM into the current script session
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    # Install Node 20 (LTS)
    nvm install 20
    nvm use 20
    nvm alias default 20
fi

# Double-check that npm is now available
if ! command -v npm &> /dev/null; then
    echo "❌ FATAL: Failed to install or locate npm. Cannot install Pi Agent."
    exit 1
fi

# Install Pi natively via NVM's global space (no custom prefix needed)
echo "📥 Downloading @mariozechner/pi-coding-agent..."
npm install -g @mariozechner/pi-coding-agent

echo "✅ Pi Agent installed. The 'pi' command is now available."

# ---------------------------------------------------------
echo "Configuring Pi Agent models..."
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
        { "id": "qwen3.6:35b", "name": "Qwen 3.6 35B (Fast Agent)", "reasoning": false, "contextWindow": 131072 },
        { "id": "gemma4:26b", "name": "Gemma 4 26B (VRAM-Fast)", "reasoning": false, "contextWindow": 32768 },
        { "id": "qwen3-coder:30b", "name": "Qwen 3 Coder 30B (VRAM-Fast)", "reasoning": true, "contextWindow": 32768, "compat": { "thinkingFormat": "qwen" } },
        { "id": "qwen3-coder:480b", "name": "Qwen 3 Coder 480B (Titan)", "reasoning": true, "contextWindow": 8192, "compat": { "thinkingFormat": "qwen" } }
      ]
    }
  }
}
JSON

echo "✅ Pi Agent Configured with Optimized VRAM/RAM Context Limits."
