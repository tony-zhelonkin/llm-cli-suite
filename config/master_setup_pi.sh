#!/bin/bash
# Master Setup Script for Pi Agent
# Managed by llm-sync

echo "Installing Pi Coding Agent..."
npm install -g @mariozechner/pi-coding-agent

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
        { "id": "gemma4:26b", "name": "Gemma 4 26B (VRAM-Fast)", "reasoning": false, "contextWindow": 32768 },
        { "id": "qwen3-coder:30b", "name": "Qwen 3 Coder 30B (VRAM-Fast)", "reasoning": true, "contextWindow": 32768, "compat": { "thinkingFormat": "qwen" } },
        { "id": "qwen3-coder:480b", "name": "Qwen 3 Coder 480B (Titan)", "reasoning": true, "contextWindow": 8192, "compat": { "thinkingFormat": "qwen" } }
      ]
    }
  }
}
JSON

echo "Pi Agent Configured with Optimized VRAM/RAM Context Limits."
