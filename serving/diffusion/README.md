# DiffusionGemma vLLM server

The runtime that serves Google's DiffusionGemma (W4A16 int4) on `:11435`. This is the second model
backend in the toolkit — a diffusion LLM alongside the Ollama tier — reachable by the coding agent
through the same provider seam.

The server is a Python venv running vLLM. It used to live only on the box, hand-built, which made it
a load-bearing thing with no definition in the repo. This directory fixes that: the venv is now
reproducible from pinned requirements.

## Files

| File | Role |
|---|---|
| `requirements.txt` | the pinned load-bearing stack (torch trio + vLLM), all `+cu129`, with the index URL |
| `requirements.lock.txt` | full `pip freeze` of a known-good venv, for a byte-exact rebuild |
| `build-venv.sh` | builds the venv from either file and verifies it imports + sees the GPU |

## Build it

```bash
serving/diffusion/build-venv.sh                 # default path /data1/venvs/diffusion
LOCK=1 serving/diffusion/build-venv.sh          # byte-exact from the lockfile
```

The default path matches `systemd/diffusiongemma.service` (`ExecStart=/data1/venvs/diffusion/bin/vllm`).
Build elsewhere and you edit the unit to match.

## Why the stack is pinned this way

The GPU driver is frozen at 565 (CUDA 12.7) for reasons that have nothing to do with this model —
a Secure Boot and boot-disk ordeal I didn't want to reopen. The plain `pip install vllm` pulls a
build compiled for CUDA 13, which needs a 580 driver and won't load on 565.

The way through: CUDA 12.9 runs on a 12.7 driver (same major version, minor-version compatibility).
vLLM ships a `cu129` wheel, so the whole stack — torch, torchvision, torchaudio, vLLM — is pinned to
`+cu129`. The trio has to match exactly; a stray cu130 torchvision or torchaudio makes vLLM's import
die on a missing kernel symbol.

The full story is in [`../../docs/story-serving-a-diffusion-llm.md`](../../docs/story-serving-a-diffusion-llm.md);
the runbook for actually serving and testing it is
[`../../docs/diffusiongemma-testing.md`](../../docs/diffusiongemma-testing.md).
