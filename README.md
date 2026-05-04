# LLM Workstation Tools

A lightweight, decoupled CLI suite designed to safely manage, monitor, and synchronize massive local LLMs (like Qwen 480B) on high-performance Linux workstations without triggering Out-Of-Memory (OOM) crashes or terminal deadlocks.

## Hardware Environment

This suite was developed, optimized, and tested against the `qwen3-coder:480b` model on the following hardware:

- **Workstation:** Dell Precision 7960 Tower
- **CPU:** Intel Xeon w9-3475X (36 cores/72 threads, base 2.2GHz, boost 4.8GHz)
- **RAM:** 512GB DDR5-4800 ECC RAM
- **GPU:** NVIDIA RTX 5000 Ada (32GB GDDR6, compute capability 8.9)
- **Storage:** 1TB NVMe SSD (OS/Scratch) + 2×8TB SATA HDDs (Data storage, where models page from)

## Tools Included

- `llm-manage` : Interactively loads/flushes Ollama models. Injects strict context window limits at boot time to prevent KV Cache runaway. Uses `VmRSS` monitoring to alert only when the model is physically hot in DDR5 RAM.
- `llm-status` : A dashboard combining `free -h`, `nvidia-smi`, and `ollama ps` to instantly display system RAM, VRAM, and loaded model state.
- `sys-notify` : Secure push notification sender (reads from `~/.config/pushover.env`).
- `sys-ram-watchdog` : Stateful background daemon that alerts on 90% and 99% RAM/VRAM capacity.
- `llm-sync` : Discovers `.devcontainer` folders across workspace roots and dynamically injects the master LLM config.

## Installation

Run `./install.sh` to symlink these tools into your `~/.local/bin` and enable the background systemd watchdog.

You will need to create `~/.config/pushover.env` with your API keys for notifications.

## Documentation

See the `docs/` directory for detailed explanations on LLM memory physics, the `mmap` trap, and how we optimized Context Windows vs KV Cache.
