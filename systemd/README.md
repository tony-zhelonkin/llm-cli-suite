# systemd — Ollama service tuning + watchdog unit

Version-controlled copies of the systemd files this workstation relies on. Linux only — the
macOS equivalents are in [`../launchd/`](../launchd/README.md).

## `ollama.override.conf`

The **global Ollama tuning** — the centralised layer. Deployed at:

```
/etc/systemd/system/ollama.service.d/override.conf
```

```ini
[Service]
Environment="OLLAMA_MODELS=/data2/llm-local"    # models on the HDD array, not the OS NVMe
Environment="OLLAMA_HOST=0.0.0.0"               # reachable from Docker via 172.17.0.1 bridge
Environment="OLLAMA_KEEP_ALIVE=-1"              # pin a loaded model indefinitely
Environment="OLLAMA_FLASH_ATTENTION=1"          # IO-aware attention (RTX 5000 Ada)
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"         # 8-bit KV cache — ~halves context VRAM
```

Deploy:

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d/
sudo cp ollama.override.conf /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload && sudo systemctl restart ollama.service
```

Full explanation of every knob: [`../docs/ollama-tuning.md`](../docs/ollama-tuning.md).
Security note on the `0.0.0.0` bind: [`../docs/SECURITY.md`](../docs/SECURITY.md).

## `sys-ram-watchdog.service`

Runs `sys-ram-watchdog` as a background daemon (stateful RAM/VRAM alerting, hysteresis
90% / 99% / reset 85%). Installed by `install.sh`. `ExecStart` uses `%h` (your home), so the
unit isn't tied to my username.
