# Tests

Two halves: an **offline suite** (runs anywhere, no GPU — this is what CI runs) and an **on-box
check** (confirms the running workstation matches the repo).

```bash
make test      # offline suite — CI runs exactly this
make verify    # on-box: is the live system what the repo says?
```

## Offline suite (`tests/run.sh`)

| File | Covers |
|---|---|
| `test_render.sh` | the renderer — NO-OP golden gate, field stripping, env host override, multi-provider merge, host normalisation (`0.0.0.0`, bare `host:port`, …), environment detection, `llm-agent-config`. A bug here breaks every devcontainer, so it's locked hardest. |
| `test_config.sh` | provider JSONs valid, one provider key each, `_hostEnv`/`_defaultHost` declared, models have id+contextWindow. |
| `test_install.sh` | `install.sh` from scratch into a throwaway HOME, **both OS branches** (`LLM_SUITE_OS`, stub `systemctl`/`launchctl` — nothing real is enabled): every tool linked, `gpu-switch` skipped on a Mac, launchd plist rendered + bootstrapped once, idempotent on re-run. |
| `test_platform.sh` | `lib/platform.sh` RAM/VRAM probes against fake `sysctl`/`vm_stat`/meminfo; `llm-status`, the watchdog and `gpu-switch`'s refusal on a "Mac" with no `nvidia-smi`. |
| `test_sync.sh` | `llm-sync` against throwaway workspaces via `LLM_SYNC_ROOTS`; the shipped `setup_pi.sh` renders on its own. |
| `test_portability.sh` | static lint: no `mapfile`, `declare -A`, `sed -i`, `readlink -f`, `grep -P`, `/proc`, … in code a Mac can reach. Mark a deliberate line `# linux-only`. |
| `test_syntax.sh` | `bash -n` on every script; `shellcheck -S error` if installed (`SHELLCHECK=` to point at a binary). |

Everything runs under bash 3.2. CI runs the suite twice: on Ubuntu, and on `macos-latest` under
Apple's stock `/bin/bash`, which is the real check for the Mac branches the Linux job can only fake.
`run.sh` re-uses whichever bash started it, so `/bin/bash tests/run.sh` tests 3.2 end to end.

`golden/models.ollama-only.json` is the frozen expected render. CI fails if it drifts from a fresh
render, so tested behaviour and shipped behaviour can't diverge. Regenerate deliberately with
`make golden` after an intentional renderer change.

## On-box check (`tests/verify-live.sh`)

CI can't see your workstation. This closes that gap — it fails if you hand-edited something live that
never made it back to git:

- `~/.pi/agent/models.json` still matches a fresh render from `config/providers/` *for this
  environment* (on the bare host that's `localhost`; fix with `llm-agent-config`).
- the `bin/` tools on `PATH` resolve into *this* repo, not a stale copy.
- the diffusion venv matches `serving/diffusion/requirements.lock.txt`.
- the systemd unit's `ExecStart` binary actually exists.
