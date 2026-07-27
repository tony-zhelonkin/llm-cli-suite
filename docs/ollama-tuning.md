# Ollama — Global Tuning: KV Cache Quantization, Flash Attention, and Where It All Lives

> **What this is**: the one place that explains the *centralised* Ollama tuning on this
> workstation — the systemd override — and how it relates to the *per-model* Modelfile tuning.
> Two different layers, easy to confuse, so I am writing down which knob lives where.

---

## Two layers, do not confuse them

I kept half-remembering this wrong, so here it is flat:

1. **Global / centralised (systemd override):** *how* the KV cache is stored and how the server
   behaves for every model. Set once, applies to all. This is the KV-cache quantization and
   flash attention. → `systemd/ollama.override.conf`.
2. **Per-model (Modelfile):** the *size* of the context window (`num_ctx`) and the sampler
   behaviour (temperature, top_k, penalties) baked into each individual model. → `modelfiles/`,
   see [modelfile-surgery.md](modelfile-surgery.md).

If a model is "stupid after 30k tokens" that is layer 2 (its Modelfile `num_ctx`). If the KV
cache is eating too much VRAM, that is layer 1 (the cache type). They are independent.

---

## The systemd override (layer 1)

Lives on the host at:

```
/etc/systemd/system/ollama.service.d/override.conf
```

A version-controlled copy is shipped in this repo at `systemd/ollama.override.conf`. Contents:

```ini
[Service]
Environment="OLLAMA_MODELS=/data2/llm-local"
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
```

What each line does and why I set it:

- **`OLLAMA_MODELS=/data2/llm-local`** — models live on the big HDD array, not the 123GB OS NVMe.
  Learned this the hard way: Ollama writes `-partial` download blobs to its *root* directory
  regardless of symlinks, and a 290GB pull nearly filled the OS drive. Point the root at the
  array from the start.
- **`OLLAMA_HOST=0.0.0.0`** — bind all interfaces so Docker devcontainers can reach the host
  Ollama over the `172.17.0.1` bridge. Security caveat: this exposes the API to the network with
  no auth — see `docs/SECURITY.md`. On a workstation used only for local SSH inference, prefer
  `127.0.0.1`.
- **`OLLAMA_KEEP_ALIVE=-1`** — pin a model in memory indefinitely once loaded, so the agent does
  not pay a reload every few minutes. `llm-manage` relies on this to hold a model hot.
- **`OLLAMA_FLASH_ATTENTION=1`** — IO-aware attention, well-optimised for the RTX 5000 Ada
  (compute 8.9). Keeps generation from crawling as the context grows past a couple thousand
  tokens.
- **`OLLAMA_KV_CACHE_TYPE=q8_0`** — store the KV cache in 8-bit instead of FP16. **This is the
  big VRAM win.** A 32k window on a 35B model is ~6–8 GiB of cache in FP16; at `q8_0` it is
  ~1.9 GiB. That reclaimed VRAM is what lets me keep the whole model plus a 128k window resident
  on a single 32GB card instead of spilling layers to DDR5.

Apply it:

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d/
sudo cp systemd/ollama.override.conf /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart ollama.service
```

---

## The payoff, and the tier that survived

With `q8_0` + flash attention, the 27–35B models sit entirely in the 32GB card with a real 128k
window and run at 15–80 t/s. That is the tier I actually use. The 480B "Titan" that motivated the
original OOM firefighting is retired — it ran at 2–5 t/s out of system RAM and was unusable as an
interactive agent (the 480B was retired as unusable — see the origin story).

---

## TL;DR

- KV cache quantization and flash attention are **global**, in the systemd override — one file.
- Context window size and samplers are **per-model**, in the Modelfiles — see [modelfile-surgery.md](modelfile-surgery.md).
- `q8_0` roughly halves KV-cache VRAM; that headroom is what keeps a 35B + 128k fully on the GPU.
- Models on `/data2` (HDD array), bind `0.0.0.0` for Docker, `keep_alive -1` to pin.
