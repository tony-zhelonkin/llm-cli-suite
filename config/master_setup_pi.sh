#!/bin/bash
# Master Setup Script for Pi Agent
# Managed by llm-sync

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

if ! grep -q "free-gpu" ~/.bash_aliases; then
    echo "alias free-gpu='curl -s http://172.17.0.1:11434/api/generate -d \"{\\\"model\\\": \\\"qwen3-coder:30b\\\", \\\"keep_alive\\\": 0}\" > /dev/null && curl -s http://172.17.0.1:11434/api/generate -d \"{\\\"model\\\": \\\"qwen3-coder:480b\\\", \\\"keep_alive\\\": 0}\" > /dev/null && curl -s http://172.17.0.1:11434/api/generate -d \"{\\\"model\\\": \\\"gemma4:26b\\\", \\\"keep_alive\\\": 0}\" > /dev/null'" >> ~/.bash_aliases
fi
