# Architecture — Workstation CLI tools for local-model management

> **Problem solved**: Replaced arbitrary shell commands with a clean, decoupled, and secure set of CLI tools to manually load, flush, monitor, and sync massive LLMs (like Qwen 480B) across multiple bioinformatics projects.

---

## Quickstart Guide

- **Monitor Hardware:** Run `llm-status`
- **Load a Model:** Run `llm-manage load 8192` (Use 8k context for the 480B Titan).
- **Flush RAM/VRAM:** Run `llm-manage flush`.
- **Update Project Configs:** Edit `~/.scripts/master_setup_pi.sh` then run `llm-sync`.
- **Background Watchdog:** Stateful alerting (Warns at 90%, Critical at 99%, Resets at 85%).

---

## The Mental Model / Why This Happens

Loading a massive LLM (like the 290GB Qwen 480B) is a multi-stage OS process. We use a **Separation of Concerns** architecture to manage the "mmap trap" and the "KV Cache spike."

I also implemented a **Single Source of Truth** for Devcontainers. Because Docker cannot follow symlinks outside the project root during a build, we use a Master Script + Sync tool pattern to propagate configurations without duplication.

---

## What Happened / Diagnostic Steps

I broke the workstation management into five distinct "pillars". *Click the links below to view the source code.*

### The Communicator (`sys-notify`)
👉 [[Script - sys-notify]] | 👉 [[Config - pushover.env]]
Responsible *only* for sending push notifications.

### The Model Manager (`llm-manage`)
👉 [[Script - llm-manage]]
Interactively loads/flushes models. Now supports **Context Window Injection** at boot time to prevent OOM deadlocks. Uses `VmRSS` monitoring to ensure the model is physically hot before notifying.

### The Dashboard (`llm-status`)
👉 [[Script - llm-status]]
A rapid readout of System RAM, VRAM, and currently resident LLM runners.

### The Watchdog (`sys-ram-watchdog`)
👉 [[Script - sys-ram-watchdog]] | 👉 [[Config - sys-ram-watchdog.service]]
A stateful background daemon. It prevents notification spam by using a hysteresis loop (Alerts at 90%, locks, only resets if usage drops below 85%).

### The Sync Tool (`llm-sync`)
👉 [[Script - llm-sync]] | 👉 [[Script - master_setup_pi.sh]]
Propagates the master `setup_pi.sh` configuration to all registered bioinformatics project directories. This ensures that any changes to your model preferences or context limits are applied globally across all Devcontainers.

---

## Architecture / Key Concept Lesson

1. **SRP (Single Responsibility Principle):** Separate secrets, notifications, and logic.
2. **mmap vs VmRSS:** Use `/proc/[PID]/status` to measure physical RAM residency. 
3. **Build Context Limitations:** Docker cannot follow symlinks to `~`. Use a sync/propagation script to maintain local copies of global configs inside project folders.
4. **Hysteresis in Monitoring:** Use "Warm" and "Cool" thresholds (90% / 85%) to prevent flapping notifications.

---

## TL;DR

- Replaced ad-hoc commands with a structured suite in `~/.local/bin/`.
- Use `llm-sync` after editing `~/.scripts/master_setup_pi.sh` to update all your projects.
- Use `llm-manage load 8192` for the big model.
- Monitor with `llm-status`.

---
_Created: 2026-05-04 | Context: Implementing a secure, set of CLI tools to manage massive local Ollama models and ensure configuration consistency across Docker Devcontainers._