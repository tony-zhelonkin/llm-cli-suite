---
name: delegate-cli
description: >-
  Hand off or consult work to the local `codex` (OpenAI) and `agy` (Gemini) CLIs in headless mode.
  Trigger when Anton says "implement/do X via codex/agy", "consult codex/agy", "have codex/agy do/write
  X", "have agy web-research X", or similar. Covers headless flags, local model/account quirks,
  sandbox fallbacks, installation, and safe multi-agent fan-out.
license: MIT
metadata:
  scope: concept
  requires: []
  skill-author: SciAgent-toolkit
  last-reviewed: 2026-07-16
  category: workflow
  tier: standard
  tags:
  - tooling
  - planning
  complementary-skills:
  - reasoning-trace
  - architecture-first-dev
---

# Delegating to codex & agy (headless)

These peer coding CLIs may be available on the current host. Run them non-interactively, capture their
output, and relay the result. The account/model and devcontainer notes below are a verified **local
profile**, not assumptions to make on other operating systems or environments.
Pick by strength: **codex** = OpenAI GPT-5.x, sharp implementer/reviewer. **agy** = Gemini 3.x, large
context + strong web research.

## Preflight and installation

Check the requested CLI before preparing a long run (`command -v codex` / `command -v agy` on POSIX;
use the shell's equivalent executable lookup elsewhere). If it is missing, do not silently substitute a
different agent. Tell the user what is unavailable and offer the official installer:

```bash
# OpenAI Codex CLI
curl -fsSL https://chatgpt.com/codex/install.sh | sh

# Google Antigravity CLI (`agy`)
curl -fsSL https://antigravity.google/cli/install.sh | bash
```

Fetching and executing a remote installer changes the user's system and uses the network: ask before
running it. Afterward, verify with `codex --version` or `agy --version`; if the executable is not on
`PATH`, ask the user to reload/restart their shell. Follow the CLI's own sign-in flow and never ask the
user to paste credentials into chat. The commands above are POSIX-shell examples; give PowerShell or
other OS-appropriate instructions when that is the user's environment.

## codex (OpenAI) — `codex exec`

```
codex exec --skip-git-repo-check -m gpt-5.5 -s <sandbox> [-o OUT.txt] "PROMPT" < /dev/null
```

- **`-m gpt-5.5` is mandatory.** Verified on Anton's ChatGPT account: `gpt-5.5` and `gpt-5.4` work;
  **every `-codex` variant fails 400** ("not supported when using Codex with a ChatGPT account"), and the
  config default `gpt-5.2-codex` is one of them — so omitting `-m` errors out. Use `gpt-5.5` (newest).
- **`--skip-git-repo-check`** — this vault is not a git repo; codex refuses to run without it.
- **`< /dev/null`** — headless codex otherwise blocks on "Reading additional input from stdin…".
- **Sandbox `-s`** picks what it may touch: `read-only` (consult/review/plan), `workspace-write` (let it
  edit files here), `danger-full-access` (avoid). `exec` runs with approval `never` already.
- **Clean output:** `-o OUT.txt` writes only the final message to a file (stdout is noisy — header,
  reasoning, token count). Read that file. `--json` for event stream, `--search` to enable web search,
  `-C DIR`/`--add-dir DIR` to set/extend the writable root.

## agy (Gemini) — `agy -p`

```
agy [--model "Gemini 3.1 Pro (High)"] [--sandbox] [--add-dir DIR] --print "PROMPT"
```

- **`-p` (`--print`) takes the prompt as its VALUE** — the prompt must be the token *immediately after*
  `-p`/`--print`, with **no other flag between `-p` and the prompt** (put the rest before `-p`, or after
  the prompt — see the `--add-dir` section). (verified 2026-07-16). If any flag sits between
  `-p` and the prompt, `-p` swallows that flag as its value and the real prompt is dropped — the model
  then replies with a generic "How can I help you today?" or comments on the stray flag (e.g. "It looks
  like you provided `--dangerously-skip-permissions`…"), and `--model` silently reverts to the Flash
  default. **Symptom of this bug: a one-line, off-topic report.** A multi-line prompt via
  `--print "$(cat brief.md)"` works fine as long as it's the immediate `-p` value.
- Default model **Gemini 3.1 Pro**; good default for web research and big-context reads. Other names from
  `agy models` (e.g. `Gemini 3.5 Flash (High)`, `Claude Opus 4.6 (Thinking)`); pass via `--model "<exact
  display name>"`. `Gemini 3.1 Pro (High)` is verified to drive real web search.
- `--sandbox` restricts the terminal; `-c`/`--continue` resumes the last conversation; `--print-timeout`
  default 5m (raise for deep research, e.g. `--print-timeout 10m`).
- **`--dangerously-skip-permissions` auto-approves agy's own tool prompts** — needed for unattended /
  background research so it doesn't block. But the Claude Code **auto-mode classifier blocks this flag**
  unless the user explicitly authorized it in-turn (matches the `DANGEROUSLY_*` bypass pattern); asking
  to "use agy" does NOT authorize it. Either wait for that authorization, or run without the flag when
  the task needs no gated tools.

## How to drive them from here

1. **Compose a self-contained prompt** — they don't share our chat. State the task, the files/paths
   (absolute, quoted — spaces), and the exact deliverable shape.
2. **Run in background** if it's real implementation (`run_in_background: true`) — these take minutes.
3. **Relay, don't dump.** Summarize what came back; show their diff/answer. For codex edits in
   `workspace-write`, review the changed files yourself before telling Anton it's done.
4. **Match tool to ask:** implementation/code-review → codex; web research / very large context → agy.
   When Anton names one, use that one.

## codex sandbox constraints (workspace-write, verified firsthand)

**The clean pattern: codex writes files; the orchestrator (you, unsandboxed) builds and commits.**

- **No git writes.** `.git` is readable but not writable — `git add` fails with `Unable to create .../.git/index.lock: Operation not permitted`. Never put commit instructions in a codex prompt; they'll fail and waste a turn. After codex finishes editing files, `git add` / `git commit` in the main session yourself.
- **No build/probe steps that touch the kernel.** `quarto render` (and likely similar tools) does a macOS `sysctl` architecture probe that the seatbelt sandbox blocks → dies with "unrecognized architecture" before loading the project. Let codex write the files; run `quarto render` yourself in the main session. Generalize: any tool that probes the machine (arch detection, hardware queries) needs to run outside the sandbox.
- **Network is off.** No outbound connections under `workspace-write` — CDN, npm, font fetches all fail. Seed any external assets (fonts, data files) into the workspace before launching codex.
- **Writable roots are printed in the codex header**, e.g. `sandbox: workspace-write [workdir, /tmp, $TMPDIR]`. Reads elsewhere on disk are fine — you can point codex at absolute paths outside the workspace to read specs or docs.
- **Images via `-i`.** `-i IMAGE` attaches images to the prompt; gpt-5.5 is vision-capable. Repeat per file. Useful for design-to-code (e.g., feed Figma board screenshots).
- **Long prompts: use stdin.** `codex exec … - < /abs/prompt.md` (the `-` reads from stdin). Avoids shell-escaping hell for multi-paragraph prompts. Use `< /dev/null` only when the full prompt is in the inline arg and you just want to stop it blocking on stdin.

## devcontainer bwrap restriction (observed 2026-06-29)

This is one observed Linux/devcontainer failure mode, not a universal diagnosis. On another host,
preserve and report the exact sandbox error (for example namespace/bwrap, seatbelt, or container-policy
denials) and offer that platform's supported environment fix rather than prescribing Linux kernel or
Docker settings blindly.

**Problem:** In this devcontainer (Docker, seccomp filter active), `read-only` and `workspace-write` both fail completely. Every shell command and `apply_patch` exits with:
```
bwrap: No permissions to create a new namespace, likely because the kernel does not allow non-privileged user namespaces.
```
Codex uses bwrap (bundled at `~/.codex/packages/standalone/.../codex-resources/bwrap`) for ALL non-`danger-full-access` sandboxes. The Docker default seccomp profile blocks `clone(CLONE_NEWUSER)` — the syscall bwrap needs — even though `user.max_user_namespaces` is non-zero.

**Root cause:** `.devcontainer/devcontainer.json` was missing `--security-opt seccomp=unconfined`. **Fixed** (added to `runArgs`). Requires devcontainer rebuild to take effect.

**Workaround until rebuild:** Use `-s danger-full-access` — this skips bwrap entirely and runs without any sandbox. File writes work, shell commands work. **Anton's preference:** run `danger-full-access` commands himself via `! codex exec ...` in the Claude Code prompt, then tell me so I monitor artifact creation. The auto-mode classifier blocks me from invoking `danger-full-access` autonomously (it matches the `DANGEROUSLY_*` pattern and requires explicit user authorization).

Asking to “use codex” authorizes Codex, **not** disabling its sandbox. Never infer approval for
`danger-full-access`; require the user to run the exact command or explicitly approve that unsandboxed
retry. Do not change host security settings, container privileges, kernel settings, or sandbox mode
without approval. When unsandboxed execution is approved, prepend the allowed working directory/files
and re-forbid git, network, credentials/secrets, dependency installation, destructive commands, and
out-of-scope writes. Prompt constraints reduce risk but do not recreate a sandbox.

**Pattern for Anton to run:** `! codex exec --skip-git-repo-check -m gpt-5.5 -s danger-full-access - < /abs/prompt.md` — Anton runs in the `!` prefix; I prepare the prompt file and monitor output.

**After rebuild:** All three modes (`read-only`, `workspace-write`, `danger-full-access`) should work normally.

**Still failing 2026-07-14** — the `--security-opt seccomp=unconfined` runArg is present in `devcontainer.json` but the running container was not rebuilt with it, so `workspace-write` still bwrap-fails on first shell-out (`read-only` answers pure Q&A but dies the moment it inspects a file). `danger-full-access` (run by Anton via `!`, or explicitly authorized in-turn) remains the working path. Note: a `read-only` probe passing does NOT prove `workspace-write` will run.

## agy --add-dir quirk (observed 2026-06-29)

**Problem:** Passing `--add-dir DIR` BEFORE the prompt triggers agy's agentic mode — it treats the directory as a Claude Code project workspace and starts exploring it autonomously instead of executing the print-mode task.

**Correct order:** PROMPT must come immediately after `-p`, then flags after:
```bash
# CORRECT — prompt first, add-dir after
agy -p "$(cat prompt.txt)" --add-dir /path/to/dir --model "..." --print-timeout 10m

# WRONG — add-dir before prompt triggers agentic exploration
agy -p --add-dir /path/to/dir "$(cat prompt.txt)"
```

**Also wrong:** Putting "Write your output to /path/to/file.md" in the prompt text also triggers agy's agentic file-write mode. Always capture stdout via shell redirect (`> output.md`) instead.

**Even "Write a well-structured markdown report" triggers it** (verified 2026-07-16). agy interprets any
"write a … report/file" phrasing as a task to author a file, saves it to its own brain dir
(`~/.gemini/antigravity-cli/brain/<uuid>/<name>.md`), and prints only a short summary + a `file://` link
to stdout — so your redirected `> report.md` captures the summary, not the report. **Fix:** phrase the
deliverable as *print to stdout* — e.g. "Answer in markdown." / "Respond with a structured markdown
answer." — and never use the verb "write". If it already went agentic, the full report is in the linked
brain-dir path; `cp` it into place.

**Working pattern (from orchestrate.sh):**
```bash
agy -p "$(cat "$SCRATCHPAD/prompt.txt")" \
    --add-dir "$RESEARCH_DIR" \
    --print-timeout 10m \
    > "$RESEARCH_DIR/output.md" 2>&1 &
```

## Traceability — persist the brief AND the report (house rule)

Every delegated research run must leave a **replayable paper trail on disk**, not
just a relayed summary. Mirror the existing `docs/llm-research/` layout:

```
docs/llm-research/<YYYY-MM-DD-subject>/
  brief_<n>_<slug>.md    # the prompt, in brief style (Context + Questions),
                         #   with a header naming the CLI/model + the report file
  report_<n>_<slug>.md   # the agent's stdout, VERBATIM, under a provenance header
  SYNTHESIS.md           # (optional) orchestrator's cross-report synthesis
```

- The `brief_*.md` is the human-readable twin of the prompt file you piped to the
  CLI — write it in the same **Context + Questions** shape as the other briefs so
  the prompt-to-answer chain is auditable.
- The `report_*.md` is the raw agent answer (agy stdout / codex `-o` file) with a
  one-line provenance header (CLI, model, date, which brief). Do not paraphrase it
  into the report file — relay a summary in chat, but keep the artifact verbatim.
- Cross-link both to the consuming `docs/plans/...` doc so a reader can walk
  brief → report → plan. This is what makes the delegated evidence citable later.

## Quick map

| Ask | Command skeleton |
|---|---|
| Consult codex (read-only) | `codex exec --skip-git-repo-check -m gpt-5.5 -s read-only -o OUT.txt "…" < /dev/null` |
| Have codex implement here | `codex exec --skip-git-repo-check -m gpt-5.5 -s workspace-write "…" < /dev/null` |
| codex web search | add `--search` |
| Long prompt via file | `codex exec … -m gpt-5.5 -s workspace-write - < /abs/prompt.md` |
| Attach image(s) | add `-i /abs/image.png` (repeat per file) |
| Consult agy | `agy -p "…"` |
| agy web research | `agy -p "research …; cite sources"` |

## Fan-out orchestration defaults (multi-agent delegation)

When fanning out real work across these CLIs plus Claude subagents (verified 2026-07-14 on the JIA
heat-vs-hypoxia stage), these defaults hold up:

- **Keep fan-out bounded and independent.** Default to two or three workers with one concrete
  deliverable each. Parallelize read-only reviews/research freely within policy, but never let writers
  edit the same file or overlapping directories. Give each writer an exclusive path/worktree or ask
  for a patch-only deliverable, then integrate serially.
- **Separate permissions.** Network-enabled research, workspace writes, and unsandboxed execution are
  distinct authorizations; approval for one does not imply either of the others. Give every run unique
  prompt/output paths and do not reuse `agy --continue` across independent workers.

- **Split by model strength, and keep reviewer ≠ author.** codex (GPT) implements → a *different*
  model family (a Claude/Opus subagent) reviews the code → agy (Gemini) does the domain-knowledge /
  large-context interpretation (e.g. classifying gene-set biology) → the orchestrator integrates,
  RE-RUNS to verify, and commits. Cross-model review only adds signal when the reviewer did not write
  the code — never have one Claude both author and review.
- **Probe before the long job.** A tiny read-only call (`codex exec … -s read-only -o probe.txt "say
  CODEX_OK" < /dev/null`, or `agy -p "reply OK"`) confirms the CLI runs here before you launch a
  multi-minute unattended job. Caveat: in the devcontainer a passing `read-only` probe does NOT prove
  `workspace-write` works (see the bwrap section) — read-only dies as soon as it shells out.
- **Self-contained prompts, composed from files, piped via stdin.** These CLIs don't see your chat:
  state the task, absolute quoted paths, the infra to reuse, the exact output contract, the house
  rules, and where to save reasoning. Keep a reusable spec file and prepend a small per-run note:
  `cat prepend.md spec.md | codex exec … -`.
- **Clean capture + orchestrator owns the artifacts.** codex: `-o OUT.txt` (final message only) and
  redirect the noisy stream separately (`> stream.log 2>&1`). agy: `-p` prints clean to stdout →
  redirect to a file (do NOT ask agy to write files — triggers agentic mode / permission hangs). For
  stateful research, have the orchestrator save each agent's stdout under `docs/_internal/reasoning/`
  (or tell codex, which can write, to save there) so the multi-model chain is traceable and replayable.
- **Background the slow ones** (`run_in_background`), each with its own scratch OUT path; read the OUT
  file on the completion notification, then relay — don't dump the raw stream.
- **codex must never run git.** Under `workspace-write`, Git metadata writes are denied and can waste
  the run while leaving worktree edits behind; under `danger-full-access` it genuinely could commit or
  push. Put "do NOT run git" in the prompt and commit yourself after reviewing
  the diff. Under `danger-full-access`, re-assert ALL guardrails in the prompt (no git, no network,
  scope to one dir) — the sandbox is no longer enforcing them.
- **Verify, don't trust.** Headless codex prints `reasoning effort: none` by default; for hard tasks
  that is thin — consider a higher-reasoning model (`-m gpt-5.6-sol`) and always re-run the produced
  artifact yourself before believing its numbers or committing.
