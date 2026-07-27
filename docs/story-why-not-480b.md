# Why I stopped chasing the biggest model

*How a 480B experiment taught me to fit the GPU instead of fighting it.*

## What I wanted

A serious local coding model on my own workstation, no API. I had 512GB of system RAM and a 32GB
GPU, and the obvious temptation was to run the largest thing that would load — `qwen3-coder:480b`.

If it fits in memory, surely it runs?

## What I tried

It loaded, in the sense that Ollama accepted it. But 480B of weights don't fit in 32GB of VRAM, so
most of them lived in system RAM and paged off the SATA disks on demand.

The result: 20–30 minute cold starts while it pulled weights off spinning disk, and a few tokens
per second once running, because every pass reached across PCIe and off disk.

To keep it from crashing I had to clamp the context hard, which threw away the one thing a giant
model was for.

I spent real time tuning around this — watching `VmRSS` to know when the model was hot in RAM,
trimming context to stay under the OOM cliff. A lot of effort to keep something slow upright.

## Where it landed

The realisation was simple once I stopped resisting it: a model that spills out of VRAM is the
wrong model, however much RAM you have. RAM is a place to store weights, not to run them. The moment
they page over PCIe or off disk, throughput falls off a cliff.

So I inverted the goal. Not the biggest model that fits in memory — the best model that fits
entirely on the GPU.

On 32GB that's a well-quantized 27–35B: 4-bit weights, KV cache quantized to `q8_0` so a full 128k
window still fits alongside them. It stays resident, cold start is seconds, and it's fast. One model
at a time, chosen to fit.

That posture is what the rest of the toolkit assumes. `llm-manage` loads one model and pins its
context so the cache can't creep past the budget. `llm-status` shows me if anything has quietly
spilled into RAM. The tuning lives in version control —
[`ollama-tuning.md`](ollama-tuning.md) for the global KV and flash-attention settings,
[`modelfile-surgery.md`](modelfile-surgery.md) for baking context and samplers per model.

## What I took away

- On a single GPU, VRAM is the only budget that matters. System RAM stores models; it doesn't run them.
- Two things compete for that budget: weights and KV cache. Quantize both and a 35B model with a
  128k window fits in 32GB. Skip that and you fight OOM.
- Cold-start time is a signal. Half an hour to load means the weights are coming off disk, and you've
  already lost.
- The full memory math — the `mmap` spill trap, why the 480B OOM'd — is in
  [`memory_physics.md`](memory_physics.md).
