# The physics of KV cache, the mmap trap, and 480B OOM crashes

The memory math behind [why I stopped chasing the 480B model](story-why-not-480b.md). The OOM
crashes weren't the weights — they were the KV cache the agent's long context requests forced open.
This is how that works, and how to reason about the VRAM budget on a single card.

---

## The Empirical Journey: How We Broke the Machine

We started with a theoretical assumption: A quantized 480B parameter model is ~290GB. Therefore, it should easily fit into a 512GB RAM workstation. 

We used a background loader script to trigger the model load. The script reported "Ready" almost instantly. But when the `pi` agent attempted to interact with it, the system RAM immediately began to skyrocket: 190GB -> 230GB -> 261GB -> 290GB... and then the system hung, requiring a `systemctl restart ollama.service` to recover.

### Phase 1: The `mmap` Trap
The first mystery was why the load script reported "Ready" while RAM usage was only at 30GB.

By reading the `sudo journalctl -u ollama.service` logs, we discovered that Ollama uses **Memory Mapping (`mmap`)**. 
1. Ollama tells the Linux kernel: *"I want to map this 300GB file."*
2. The kernel agrees instantly, but **lazy-loads** the data. It doesn't actually pull the bytes off the spinning `/data2` HDD array.
3. The load script saw the process and fired a "Ready" notification.
4. When `pi` sent the first prompt, the kernel suddenly realized it needed the data. It triggered a massive wave of **Page Faults**, frantically copying 250GB from the HDD to DDR5. 

**The Fix:** I rewrote the `llm-manage` CLI to ignore the process state and instead monitor `/proc/[PID]/status` for **VmRSS (Resident Set Size)**. Now, the system waits for physical RAM usage to cross 180GB before declaring the 480B model "HOT." We clocked this physical transfer at exactly **14 minutes and 16 seconds**.

### Phase 2: The Context Window Crash (The KV Cache)
Once the weights were physically resident (sitting stable at ~200GB), we tried inference again. The RAM immediately spiked by another 80GB, crashing the machine.

The `pi` coding agent defaults to passing a `262,144` (or `32,768`) token context window to the API. 

This exposed the difference between two types of memory:
1. **Weights Allocation:** The static "brain" of the model (290GB).
2. **Context Window Allocation (KV Cache):** The dynamic "scratchpad" the model uses to track the conversation and generate the next token. 

The math for a KV Cache scales linearly with context length, but *multiplies* based on the model's architectural size (number of layers and attention heads). 

Because `qwen3-coder:480b` is a behemoth, asking Ollama to allocate a `32,768` token KV Cache forced it to request a contiguous ~70GB-80GB block of zeroed DDR5 RAM. This massive pre-allocation pushed the total system usage past 500GB, triggering the OOM killer.

---

## The Fix / Code Architecture

To run Titan-class models, you must manually decouple and constrain the KV Cache.

### 1. The Context Injection Fix
Ollama locks in the maximum context size *when the runner boots*. If you load a model with `"keep_alive": -1` and no context limit, it boots with its default maximum (32k). 

I rewrote `llm-manage load` to accept explicit context arguments:
```bash
# Force the runner to boot with a strictly constrained 8192 context window
curl -s http://localhost:11434/api/generate -d '{"model": "qwen3-coder:480b", "keep_alive": -1, "options": {"num_ctx": 8192}}'
```

### 2. The Devcontainer Agent Hardening
Even with the runner constrained, if `pi` asks for a 262k window, the API request fails. I had to hardcode the `models.json` file inside the Docker Devcontainers to prevent the agent from being greedy.

```json
// ~/.pi/agent/models.json
"models": [
  { "id": "gemma4:26b", "name": "Gemma (VRAM-Fast)", "contextWindow": 32768 },
  { "id": "qwen3-coder:30b", "name": "Qwen 30B (VRAM-Fast)", "contextWindow": 32768 },
  { "id": "qwen3-coder:480b", "name": "Qwen 480B (Titan)", "contextWindow": 8192 }
]
```

---

## Architecture / Key Concept Lesson

1. **VRAM Spillover:** For the 30B models, capping the context at `32768` ensures the entire KV Cache fits in the remaining ~14GB of the RTX 5000's VRAM. If it spills into System DDR5, inference drops to 1-2 tokens per second.
2. **The 14-Minute Rule:** A 480B model is never "instant." You must ping it and wait 14 minutes for the kernel to complete the `mmap` page faults from the HDD.
3. **Stateless API:** A standard `curl` to `/api/generate` forgets everything instantly. Context is maintained entirely by the client (like `pi`) passing the massive state array back and forth. 
4. **Stateful Watchdogs:** To prevent notification spam when VRAM naturally maxes out (98%), I implemented a Hysteresis loop in `sys-ram-watchdog`. It alerts at 90%, sets a lock, and only resets the lock if VRAM drops below 85% (cooling down), ensuring only one notification is sent per heavy load session.

---

## Epilogue — how the story actually ended: the 480B is retired

The fixes stabilised the machine, but they did not make the 480B *usable*.

Even fully tamed — weights resident, context clamped to 8192 to stay alive — the 480B ran 
220-250GB RAM system DDR5 across the PCIe bus at **2–5 tokens/sec**, 
after a **14-20 minute** cold start off the HDD. 

So I stopped running it. The `qwen3-coder:480b` is **retired** from the working set. What I
actually use is the 27–35B tier: fully resident in the 32GB card with a real 128k window (thanks
to `q8_0` KV-cache quantization), at 15–80 tokens/sec. 

It does not need any of the survival tricks in this note.

This note stays as the record of *why* the Titan doesn't work here — so a future me doesn't
re-pull 290GB expecting magic. The mmap/VmRSS and KV-cache lessons below are still true and still
useful; the 480B is just the cautionary example that taught them.

---

## TL;DR

- **The 480B is retired** 
- A 480B model takes ~200GB for weights, and ~80GB for a 32k KV Cache — the KV spike could also OOM
- Use `VmRSS` in `/proc` to measure true physical RAM load, not `mmap` virtual mappings.
- On the tier I kept: `q8_0` KV-cache quantization keeps a 30–35B model **plus** a 128k window
  entirely in the 32GB card — no spillover, high speed.
