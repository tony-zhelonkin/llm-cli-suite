# Why I stopped chasing the biggest model

*How a 480B experiment taught me to fit the GPU instead of fighting it.*

## What I wanted

A serious local coding model, running on my own workstation, no API. I had 512GB of system RAM and
a 32GB GPU, and the obvious temptation was to run the largest thing that would technically load —
`qwen3-coder:480b`. If it fits in *memory*, surely it runs?

## What I tried

It loaded, in the sense that Ollama accepted it. But 480B of weights don't fit in 32GB of VRAM, so
most of them lived in system RAM and paged in from the SATA disks on demand. The result:

- **20–30 minute cold starts** while it pulled weights off spinning disk into RAM.
- **A few tokens per second** once running, because every forward pass reached across the PCIe bus
  and, worse, off disk.
- To keep it from crashing at all, I had to clamp the context window hard — which threw away the one
  thing a giant model was supposed to give me.

I spent real time tuning around this: watching `VmRSS` to know when the model was physically hot in
RAM, adjusting context to stay under the OOM cliff. It was a lot of effort to make something slow
stay upright.

## Where it landed

The realisation was simple once I stopped resisting it: **a model that spills out of VRAM is the
wrong model, no matter how much RAM you have.** RAM isn't a slower VRAM; the moment weights page over
PCIe or off disk, throughput collapses and no amount of tuning brings it back.

So I inverted the goal. Instead of the biggest model that fits in *memory*, I run the best model
that fits entirely on the *GPU*. On 32GB that's a well-quantized 27–35B — 4-bit weights, with the KV
cache quantized to `q8_0` so a full 128k context still fits alongside the weights. It stays resident
on the card, cold start is seconds, and it's fast. One model at a time, chosen to fit.

That posture is what the rest of this toolkit assumes. `llm-manage` loads exactly one model and pins
its context so KV cache can't creep past the VRAM budget. `llm-status` shows me at a glance whether
anything has quietly spilled into RAM. The tuning lives in version control —
[`ollama-tuning.md`](ollama-tuning.md) for the global KV-cache and flash-attention settings,
[`modelfile-surgery.md`](modelfile-surgery.md) for baking context and samplers per model.

## What I took away

- On a single GPU, **VRAM is the only budget that matters**. System RAM is a comfortable place to
  *store* models, not to *run* them.
- The two things competing for that budget are **weights and KV cache**. Quantize both — 4-bit
  weights, `q8_0` cache — and a 35B model with a 128k window fits in 32GB. Skip that and you're
  fighting OOM.
- Cold-start time is a signal, not a nuisance. If loading takes half an hour, the weights are coming
  off disk, and you've already lost.
- The full memory math — the `mmap` spill trap, why the 480B OOM'd, how to reason about it — is in
  [`memory_physics.md`](memory_physics.md).
