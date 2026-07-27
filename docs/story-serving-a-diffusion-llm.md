# Getting a diffusion LLM onto a 32GB workstation

*A field note on serving Google's DiffusionGemma to my coding agent, on one Ada card with a driver
I did not want to upgrade.*

## What I wanted

I already had a comfortable local setup: Ollama serving a quantized 27–35B model to my Pi coding
agent, one model resident on the 32GB card at a time. Then DiffusionGemma landed — a *diffusion*
language model, not the usual left-to-right kind, and the first one vLLM could serve natively. I
wanted to feel it under my own agent, on a box I work with, and decide whether it earned a place 
next to the Ollama tier.

Two things made it awkward. My driver was frozen at 565 after a long boot-and-Secure-Boot ordeal,
so anything requiring a newer driver was off the table. 
And the card is 32GB, which is the wall everything here runs into.

## Where we came from

First instinct was to grab the model and serve it. The plain `pip install vllm` pulled a build
compiled for CUDA 13, which wants a 580-series driver — it died on import against my 565. 

So the first real question was whether I could run *any* current vLLM without moving 
the driver I'd deliberately pinned.

Turned out yes: CUDA 12.9 runs fine on a 12.7 driver (same major version), and vLLM ships a `cu129`
wheel. Installing the whole torch trio at `+cu129` got vLLM importing and allocating on the GPU with
the driver untouched. That was the unlock — no driver move, no building from source.

Then the model itself. I reached for NVIDIA's 4-bit NVFP4 build first, since it was smallest. Wrong
call — NVFP4 needs a Blackwell GPU; my Ada can't execute those kernels at all. So I dropped to the
FP8 build. It served, and I measured it: ~26GB of weights, which left only about 2GB for
context. That capped me around 14k tokens.

## Where it landed

14k wasn't enough. My agent's own system prompt and tool definitions eat most of it, so it
autocompacted almost immediately — busy summarizing itself instead of working. Clearly I needed a
smaller-weight quant so the context could breathe.

The desk research was discouraging: it concluded that 4-bit checkpoints exist but vLLM couldn't run
them for this diffusion architecture on my card. But the checkpoints were right there on Hugging
Face — someone had made them. A negative claim that costs one download to check isn't worth
trusting, so I pulled a W4A16 int4 build and just tried it.

It worked. vLLM picked its Marlin int4 kernels for both the dense and the mixture-of-experts layers
and ran the diffusion decode on top — on the Ada card, on the frozen driver. Weights dropped to
~15GB, which freed ~13GB for KV cache: a real **128k context**. Under the agent it stops
autocompacting and behaves like an actual tool.

The output is the fun part. Where the Ollama models type left to right, this one denoises a whole
block of a couple hundred tokens at once and drops it in — so the agent renders in chunks, not
word by word. That's the diffusion decode showing through, and it's fast - will have to see how 
it performs on my tasks.

## Where it plugs in

The toolkit has a seam for this: each backend is one JSON file under `config/providers/`,
merged into the agent's config by a renderer that rewrites the host per environment. 

DiffusionGemma became `diffusion.json` pointing at a vLLM server on `:11435`. 
A systemd unit runs the server; `gpu-switch` hands the single GPU between Ollama and diffusion, 
since 32GB won't hold both. 

The full runbook is in [`diffusiongemma-testing.md`](diffusiongemma-testing.md).

## What I took away

- A frozen driver isn't a dead end. CUDA's minor-version compatibility meant a `cu129` build ran on
  my 12.7 driver; the wall was an imagined one.
- Match the quant to the silicon before the size. NVFP4 was smaller but unrunnable on Ada; FP8 ran
  but left no room; a 4-bit W4A16 was the actual fit. "Smallest" and "servable" aren't the same
  question.
- On a 32GB card the model's weight footprint decides your context. Halving the weights (26GB → 15GB)
  turned a 14k toy into a 128k agent. Everything is a VRAM budget between weights and KV cache.
- Verify a negative result when the test is cheap. The research said 4-bit wouldn't serve; a 20-minute
  download proved it did
- Make tools tell the truth about state. A server that reports "started" while it's still loading, or
  a switch that sits silent for a minute while VRAM drains, both read as broken. Poll until ready;
  show the memory falling. Implemented in the 'gpu-switch' 
