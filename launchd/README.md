# launchd — the macOS side of `systemd/`

On a Mac there's no systemd. These are the launchd user agents that do the same jobs.

## `com.tony.sys-ram-watchdog.plist`

The macOS twin of `systemd/sys-ram-watchdog.service`. `install.sh` installs it for you: it fills in
your `$HOME` (launchd doesn't expand `~`), writes it to `~/Library/LaunchAgents/`, and loads it with
`launchctl bootstrap gui/$(id -u)` (or `load -w` on older macOS). Re-running the installer kicks an
unchanged, already-loaded agent (`kickstart -k`) so it runs the current code. A changed plist is
booted out and bootstrapped again. If launchd won't load it, the installer warns and still finishes.

On a Mac it only watches RAM. That's also the GPU's memory (unified), so there's no separate VRAM
check.

```bash
launchctl print gui/$(id -u)/com.tony.sys-ram-watchdog    # is it running?
launchctl bootout gui/$(id -u)/com.tony.sys-ram-watchdog  # stop + unload
```

## `com.tony.ollama-env.plist`

The macOS twin of `systemd/ollama.override.conf` — the global Ollama tuning. Ollama.app reads its
settings from the launchd environment, and `launchctl setenv` doesn't survive a reboot, so this agent
re-applies them at every login. Like the Linux override, you install it by hand:

```bash
cp launchd/com.tony.ollama-env.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tony.ollama-env.plist
# then quit and reopen Ollama.app so it picks the environment up
```

What it sets:

| Var | Value | Why |
|---|---|---|
| `OLLAMA_FLASH_ATTENTION` | `1` | same as the workstation — Metal supports it |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | ~halves context memory; needs flash attention |
| `OLLAMA_KEEP_ALIVE` | `30m` | **not** `-1` like the workstation. On a Mac the model shares memory with everything else, so pinning it forever starves the desktop. |

Not set, on purpose:

- `OLLAMA_HOST` — the default `127.0.0.1` is right for a Mac. A container on Docker Desktop still
  reaches it through `host.docker.internal`, which Docker Desktop forwards to the Mac's loopback. Only
  set `0.0.0.0` if another *machine* needs it, and read [`../docs/SECURITY.md`](../docs/SECURITY.md)
  first.
- `OLLAMA_MODELS` — the default `~/.ollama/models` is fine unless you keep models on an external
  disk. If you do, add `launchctl setenv OLLAMA_MODELS /Volumes/…;` to the string.

If you run the Homebrew service (`brew services start ollama`) instead of the app, `launchctl
setenv` reaches it too, since launchd hands the vars to every job it starts afterwards. The catch is
login: both agents start at once, so the brew one can come up before the vars are set (Ollama.app
as a login item can race it the same way). After login,
`brew services restart ollama` makes it pick them up. Don't edit
`~/Library/LaunchAgents/homebrew.mxcl.ollama.plist` by hand. `brew services start`/`restart`
regenerate it from the formula and throw the edit away.

## Not here

`gpu-switch` and `diffusiongemma.service` have no macOS twin. They manage NVIDIA VRAM and a CUDA
vLLM server; `install.sh` skips them on a Mac and says so.
