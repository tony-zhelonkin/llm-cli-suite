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
| `test_render.sh` | the renderer — NO-OP golden gate, field stripping, env host override, multi-provider merge. A bug here breaks every devcontainer, so it's locked hardest. |
| `test_config.sh` | provider JSONs valid, one provider key each, `_hostEnv`/`_defaultHost` declared, models have id+contextWindow. |
| `test_install.sh` | `install.sh` from scratch into a throwaway HOME: every `bin/` tool gets linked (catches a new tool being forgotten), links resolve into the repo, idempotent on re-run. |
| `test_syntax.sh` | `bash -n` on every script; `shellcheck -S error` if installed. |

`golden/models.ollama-only.json` is the frozen expected render. CI fails if it drifts from a fresh
render, so tested behaviour and shipped behaviour can't diverge. Regenerate deliberately with
`make golden` after an intentional renderer change.

## On-box check (`tests/verify-live.sh`)

CI can't see your workstation. This closes that gap — it fails if you hand-edited something live that
never made it back to git:

- `~/.pi/agent/models.json` still matches a fresh render from `config/providers/`.
- the `bin/` tools on `PATH` resolve into *this* repo, not a stale copy.
- the diffusion venv matches `serving/diffusion/requirements.lock.txt`.
- the systemd unit's `ExecStart` binary actually exists.
