# OpenAI `/v1` Shim Design for DiffusionGemma

> **One-line summary:** A ~150-line FastAPI shim that speaks OpenAI `/v1/chat/completions` (+ `/v1/models`, `/health`) to coding agents while hiding all diffusion sampling knobs behind a server-side config and a single pluggable `model.generate()` stub.

---

## 0. Goal & seam

```
  pi agent  ──OpenAI chat request──▶  FastAPI shim  ──generate(prompt, DIFFUSION_DEFAULTS)──▶  DiffusionGemma
 (baseUrl =                          (this doc)                                                (Python-only)
  http://HOST:PORT/v1)   ◀──OpenAI response envelope──                    ◀──text──
```

The shim is the **only** abstraction seam. Rule of thumb:
- **Client speaks OpenAI**, nothing else. It never sees `denoise_steps`, `temperature_schedule`, `entropy_threshold`.
- **Diffusion knobs live server-side** as constants/env, injected into `generate()`.
- `model.generate()` is a **pluggable stub** — the actual diffusion runtime (raw PyTorch, a custom sampler, HF `diffusers`, etc.) is decided separately and dropped in behind one function.

---

## 1. Minimal endpoints a coding agent actually needs

Coding agents (pi, aider, Continue, OpenAI SDK clients) in practice hit only three routes:

| Endpoint | Method | Needed for | Notes |
|---|---|---|---|
| `POST /v1/chat/completions` | POST | Every generation (streaming **and** non-streaming) | The one that matters. Must honor `stream: true`. |
| `GET  /v1/models` | GET | Startup / model discovery & validation | Many clients call this once to confirm the model id exists. Return a single hard-coded entry. |
| `GET  /health` (or `/healthz`) | GET | GPU-mux supervisor readiness probe | Non-OpenAI, internal. See §4. |

`/v1/completions` (legacy text completion) is **not** needed by modern chat agents; skip it unless a specific client demands it.

### 1.1 `POST /v1/chat/completions` — request fields

**Mandatory (must read):**
- `model` (string) — echo it back in the response; optionally validate against the served id.
- `messages` (array of `{role, content}`) — `role ∈ {system, user, assistant, tool}`. This is the whole conversation, resent every call (clients are stateless).

**Optional (accept, then mostly ignore / clamp):**
- `stream` (bool) — **must be honored**; switches SSE vs JSON.
- `stream_options: {include_usage: bool}` — if set, emit a final usage-only chunk.
- `max_tokens` / `max_completion_tokens` (int) — reasonable to honor as a generation cap.
- `stop` (string | string[]) — optional; honor if cheap.
- `n`, `temperature`, `top_p`, `presence_penalty`, `frequency_penalty`, `seed`, `logit_bias`, `user`, `logprobs` — **accept but do not forward to diffusion**. `temperature`/`top_p` from the client are autoregressive concepts that do NOT map to diffusion sampling; swallow them (see §3). Accepting-and-ignoring is spec-friendly: clients set these unconditionally.

> **Design choice:** accept unknown/extra fields silently (Pydantic `model_config = ConfigDict(extra="allow")`) so future client params never 422 the agent.

### 1.2 Tool / function calling

pi and similar agents rely on tool calling for file edits / shell. The **request** side you must not choke on:
- `tools: [{type:"function", function:{name, description, parameters(JSON schema)}}]`
- `tool_choice: "auto" | "none" | "required" | {type:"function",function:{name}}`
- assistant turns may contain `tool_calls`; `tool`-role messages carry `tool_call_id` + `content`.

The **response** side (what you must be able to emit if the model is to drive tools):
- `choices[].message.tool_calls: [{id, type:"function", function:{name, arguments(stringified JSON)}}]`
- `finish_reason: "tool_calls"`.

**Recommendation for v1 of the shim:** since a diffusion text model likely won't emit structured tool-call tokens natively, start **without** native tool emission — flatten `tools` into the prompt (or ignore) and always return plain `content` with `finish_reason:"stop"`. Prompt-based tool calling can be layered in later inside the `messages → prompt` renderer without changing the HTTP surface. Just make sure incoming `tools`/`tool` messages **parse** and don't error.

### 1.3 `POST /v1/chat/completions` — response envelope

Non-streaming (`object: "chat.completion"`):
```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "created": 1751932800,
  "model": "diffusion-gemma",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "..."},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
}
```
Mandatory: `id`, `object`, `created`, `model`, `choices[].{index,message,finish_reason}`. `usage` is expected by many clients — include it even with best-effort/zero token counts.

### 1.4 `GET /v1/models`
```json
{"object":"list","data":[{"id":"diffusion-gemma","object":"model","created":1751932800,"owned_by":"local"}]}
```

---

## 2. Streaming (SSE) format for `stream: true`

Transport: `Content-Type: text/event-stream`, each event is `data: <json>\n\n`, terminated by `data: [DONE]\n\n`.

Chunk object is `object: "chat.completion.chunk"` and uses `delta` (not `message`):

1. **First chunk** carries the role:
   `{"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1751932800,"model":"diffusion-gemma","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`
2. **Content chunks** carry incremental text:
   `...,"choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]`
3. **Final content chunk** sets finish_reason:
   `...,"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]`
4. If `stream_options.include_usage` was set, emit one **usage chunk** with `"choices":[]` and a populated `usage`.
5. `data: [DONE]`

> **Diffusion caveat:** diffusion models generate by iterative denoising over the *whole* sequence, not strictly left-to-right token-by-token. True incremental streaming may not exist. Two honest options:
> - **Pseudo-stream:** run `generate()` to completion, then chunk the final string into small pieces and emit them as deltas. Clients are happy; latency-to-first-token is just full gen time.
> - **Denoise-step stream:** if the runtime exposes a per-step callback, emit the diff between successive denoised drafts. More faithful but text can "rewrite" itself mid-stream, which some UIs render oddly. Prefer pseudo-stream for v1.
> - Note: if an error occurs mid-stream the HTTP status is already `200`; surface the error as a final SSE `data:` event with an `{"error":{...}}` body rather than trying to change the status.

---

## 3. Server-side diffusion defaults (the clean separation)

The diffusion knobs are **held on the server and never accepted from the client**. Client-supplied `temperature`/`top_p`/etc. are parsed (so requests validate) but dropped before `generate()`.

```python
# diffusion_config.py  — server-side ONLY, not part of the HTTP schema
from dataclasses import dataclass, field, asdict
import os

@dataclass(frozen=True)
class DiffusionDefaults:
    denoise_steps: int      = int(os.getenv("DG_DENOISE_STEPS", "64"))
    temp_schedule: str      = os.getenv("DG_TEMP_SCHEDULE", "cosine")   # baked-in
    entropy_threshold: float = float(os.getenv("DG_ENTROPY_THRESHOLD", "0.85"))
    guidance_scale: float   = float(os.getenv("DG_GUIDANCE", "1.5"))
    max_new_tokens: int     = int(os.getenv("DG_MAX_NEW_TOKENS", "1024"))

DIFFUSION_DEFAULTS = DiffusionDefaults()
```

Separation contract:
- The Pydantic **request model has no diffusion fields**; there is literally nowhere for a client to inject them (and `extra="allow"` extras are never forwarded to `generate()`).
- Only the shim reads `DIFFUSION_DEFAULTS`. Ops tune behavior via **env vars / config file**, not API calls.
- The single mapping point (`_build_gen_kwargs`) is the audit boundary: it takes the OpenAI request and returns the diffusion kwargs, and it explicitly whitelists what (if anything) a client may influence — e.g. you *may* let `max_tokens` clamp `max_new_tokens` downward, but never upward past the server cap.

---

## 4. Health / readiness for the GPU-mux supervisor

An on-demand GPU mux (spins a model onto a GPU when needed, tears it down otherwise) needs to distinguish **process is up** from **weights are resident and generate() works**. Expose two signals:

- `GET /health` (liveness) — returns `200` as soon as the FastAPI process is accepting connections. Cheap, no model touch.
- `GET /health` with a readiness flag (or a separate `GET /ready`) — returns `200` **only after weights are loaded onto the GPU**; `503` while loading.

```python
STATE = {"ready": False, "model": None, "device": None}

@app.on_event("startup")
async def _load():
    # load weights here (or lazily on first request); flip ready when resident
    STATE["model"]  = load_diffusion_gemma()   # pluggable
    STATE["device"] = current_gpu()
    STATE["ready"]  = True

@app.get("/health")
def health():
    if not STATE["ready"]:
        return JSONResponse({"status": "loading", "ready": False}, status_code=503)
    return {"status": "ok", "ready": True, "model": "diffusion-gemma", "device": STATE["device"]}
```

How the supervisor probes:
- Poll `GET /health`; treat `200 {ready:true}` as "serveable", `503` as "still warming", connection-refused/timeout as "down".
- Only route agent traffic once ready; use the same endpoint as a k8s/systemd readiness probe.
- Optional deeper check: a `GET /health?deep=1` that runs a 1-token `generate()` to confirm the GPU path actually executes (catches loaded-but-wedged states). Keep it opt-in — it costs a forward pass.

---

## 5. Minimal FastAPI implementation sketch

```python
# app.py  —  pip install fastapi uvicorn pydantic
import json, time, uuid, asyncio
from typing import Any, Optional, Union
from fastapi import FastAPI
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict

from diffusion_config import DIFFUSION_DEFAULTS   # §3

MODEL_ID = "diffusion-gemma"
app = FastAPI()
STATE = {"ready": False, "model": None, "device": None}

# ---------- OpenAI request schema (no diffusion fields exist here) ----------
class ChatMessage(BaseModel):
    model_config = ConfigDict(extra="allow")   # tolerate tool_call_id, name, etc.
    role: str
    content: Optional[Union[str, list, None]] = None

class ChatRequest(BaseModel):
    model_config = ConfigDict(extra="allow")   # never 422 on unknown client params
    model: str
    messages: list[ChatMessage]
    stream: bool = False
    max_tokens: Optional[int] = None
    stream_options: Optional[dict] = None
    # temperature/top_p/tools/etc. land in `extra` and are intentionally ignored

# ============================================================================
# PLUGGABLE STUB — the diffusion runtime is decided separately.
# Replace the body; keep the signature. Sync is fine (offloaded to a thread).
# ============================================================================
def load_diffusion_gemma():
    raise NotImplementedError("wire up the diffusion runtime here")

def model_generate(prompt: str, **gen_kwargs) -> str:
    """Return the full generated string. gen_kwargs = DIFFUSION_DEFAULTS + clamps."""
    return STATE["model"].generate(prompt, **gen_kwargs)   # <-- diffusion call
# ============================================================================

def render_prompt(messages: list[ChatMessage]) -> str:
    # Map OpenAI chat turns -> whatever DiffusionGemma expects.
    # (Swap for the model's real chat template.)
    parts = [f"<{m.role}>\n{m.content or ''}" for m in messages]
    return "\n".join(parts) + "\n<assistant>\n"

def build_gen_kwargs(req: ChatRequest) -> dict:
    """THE audit boundary: server defaults win; client may only clamp down."""
    kw = {
        "denoise_steps":     DIFFUSION_DEFAULTS.denoise_steps,
        "temp_schedule":     DIFFUSION_DEFAULTS.temp_schedule,
        "entropy_threshold": DIFFUSION_DEFAULTS.entropy_threshold,
        "guidance_scale":    DIFFUSION_DEFAULTS.guidance_scale,
        "max_new_tokens":    DIFFUSION_DEFAULTS.max_new_tokens,
    }
    if req.max_tokens:                                    # only downward clamp
        kw["max_new_tokens"] = min(kw["max_new_tokens"], req.max_tokens)
    return kw

@app.on_event("startup")
async def _startup():
    STATE["model"] = load_diffusion_gemma()
    STATE["device"] = "cuda:0"
    STATE["ready"] = True

# ---------- endpoints ----------
@app.get("/health")
def health():
    if not STATE["ready"]:
        return JSONResponse({"status": "loading", "ready": False}, status_code=503)
    return {"status": "ok", "ready": True, "model": MODEL_ID, "device": STATE["device"]}

@app.get("/v1/models")
def list_models():
    return {"object": "list", "data": [
        {"id": MODEL_ID, "object": "model", "created": 0, "owned_by": "local"}]}

@app.post("/v1/chat/completions")
async def chat_completions(req: ChatRequest):
    prompt = render_prompt(req.messages)
    gen_kwargs = build_gen_kwargs(req)
    cid = f"chatcmpl-{uuid.uuid4().hex[:24]}"
    created = int(time.time())

    if not req.stream:
        text = await asyncio.to_thread(model_generate, prompt, **gen_kwargs)
        return {
            "id": cid, "object": "chat.completion", "created": created, "model": MODEL_ID,
            "choices": [{"index": 0,
                         "message": {"role": "assistant", "content": text},
                         "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }

    async def sse():
        def chunk(delta, finish=None):
            return "data: " + json.dumps({
                "id": cid, "object": "chat.completion.chunk", "created": created,
                "model": MODEL_ID,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }) + "\n\n"

        yield chunk({"role": "assistant"})
        # Pseudo-stream: diffusion has no true token-by-token; run then slice. (§2)
        text = await asyncio.to_thread(model_generate, prompt, **gen_kwargs)
        step = 24
        for i in range(0, len(text), step):
            yield chunk({"content": text[i:i+step]})
            await asyncio.sleep(0)
        yield chunk({}, finish="stop")
        if (req.stream_options or {}).get("include_usage"):
            yield "data: " + json.dumps({
                "id": cid, "object": "chat.completion.chunk", "created": created,
                "model": MODEL_ID, "choices": [],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
            }) + "\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(sse(), media_type="text/event-stream")
```

Run: `uvicorn app:app --host 0.0.0.0 --port 8000`
Client (pi): `providers.<name>.baseUrl = http://HOST:8000/v1`, model `diffusion-gemma`, any dummy API key.

Smoke test:
```python
from openai import OpenAI
c = OpenAI(base_url="http://HOST:8000/v1", api_key="dummy")
print(c.chat.completions.create(model="diffusion-gemma",
      messages=[{"role":"user","content":"hi"}]).choices[0].message.content)
```

---

## 6. Existing minimal shims worth referencing (verified)

Do not reinvent unless you want full control. Verified projects:

- **`deepset-ai/fastapi-openai-compat`** — FastAPI router factory for OpenAI-compatible Chat Completions / Responses / Files. Handles SSE streaming, non-streaming, tool calling, custom chunk mapping, and auto-offloads sync callables to a thread pool. Your logic goes in a `run_completion(model, messages, body)` callable, and extra request fields are forwarded in `body` — the cleanest "wrap a custom `generate()`" option. https://github.com/deepset-ai/fastapi-openai-compat
- **`hrgarber/openai-compatible-api`** — minimal shim exposing `/v1/chat/completions`, `/v1/completions`, `/v1/models` over a custom LLM. Good bare-bones reference. https://github.com/hrgarber/openai-compatible-api
- **`ritun16/openai-compatible-fastapi`** — fuller example adding API-key management + rate limiting (production concerns). https://github.com/ritun16/openai-compatible-fastapi
- **vLLM OpenAI-compatible server** — the reference implementation of the surface; read it to get field semantics exactly right (heavier than you need to copy). https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html
- **FastChat `openai_api.md`** — documents which OpenAI fields a real shim implements. https://github.com/lm-sys/FastChat/blob/main/docs/openai_api.md
- Tutorial (concept + ~50-line hand-written shim): Saar Berkovich, "How to build an OpenAI-compatible API," Towards Data Science. https://towardsdatascience.com/how-to-build-an-openai-compatible-api-87c8edea2f06/

**Recommendation:** for the DiffusionGemma seam, either (a) hand-write the §5 sketch for total control over the diffusion mapping and the "no knobs to client" guarantee, or (b) adopt `fastapi-openai-compat` and put `build_gen_kwargs` + `model_generate` inside its `run_completion` callable. Both keep the diffusion runtime as a single pluggable stub.

### Spec sources
- OpenAI Chat Completions streaming events reference: https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events
- OpenAI streaming responses guide: https://developers.openai.com/api/docs/guides/streaming-responses
