#!/bin/bash
# Installer for the LLM Workstation Tools
# OS-aware and re-runnable: everything is a symlink or an idempotent service
# load, so running it again just re-asserts the same state. It only installs
# what's valid for this OS and says what it skipped.
#
# LLM_SUITE_OS=linux|macos overrides detection (the tests use it to drive the
# macOS branch on Linux with a stubbed launchctl).
set -euo pipefail

BASE_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$BASE_DIR/lib/platform.sh"
OS=$(plat_os)

echo "Setting up LLM Workstation Tools ($OS)..."

# Ensure directories exist
mkdir -p ~/.local/bin
mkdir -p ~/.scripts

# Tools valid everywhere; gpu-switch is Linux/NVIDIA only (systemd units + nvidia-smi).
TOOLS="sys-notify llm-manage llm-status llm-sync llm-agent-config sys-ram-watchdog"
if [ "$OS" = linux ]; then TOOLS="$TOOLS gpu-switch"; fi

# Create symlinks
for t in $TOOLS; do
    ln -sf "$BASE_DIR/bin/$t" ~/.local/bin/"$t"
done
ln -sf "$BASE_DIR/config/master_setup_pi.sh" ~/.scripts/master_setup_pi.sh
# llm-sync ships these provider lists into each devcontainer; keep the staging
# dir pointed at the repo so a new backend (e.g. diffusion.json) propagates.
ln -sfn "$BASE_DIR/config/providers" ~/.scripts/providers

if [ "$OS" = linux ]; then
    # Setup Systemd (user unit). No user bus — e.g. a plain ssh session without
    # lingering — is not fatal: the tools are linked, only the daemon waits.
    UNIT=sys-ram-watchdog.service
    mkdir -p ~/.config/systemd/user
    ln -sf "$BASE_DIR/systemd/$UNIT" ~/.config/systemd/user/$UNIT
    if systemctl --user daemon-reload 2>/dev/null; then
        # Already running → restart, so a re-install picks up new code (the unit
        # runs the repo's script through the symlink, but the old one is in memory).
        if systemctl --user is-active --quiet $UNIT; then
            systemctl --user enable $UNIT 2>/dev/null && systemctl --user restart $UNIT \
                && echo "   restarted $UNIT (picks up new code)" \
                || echo "⚠️  couldn't restart $UNIT — try: systemctl --user restart $UNIT"
        else
            systemctl --user enable --now $UNIT \
                || echo "⚠️  couldn't enable $UNIT — try: systemctl --user enable --now $UNIT"
        fi
    else
        echo "⚠️  skipped: enabling sys-ram-watchdog — no systemd user bus here."
        echo "    Later: systemctl --user enable --now sys-ram-watchdog.service"
    fi
    echo "ℹ️  not installed: systemd/diffusiongemma.service + ollama.override.conf are"
    echo "    root-owned — copied by hand with sudo (docs/getting-started.md)."
else
    # Setup launchd (user agent). launchd doesn't expand ~, so the plist is
    # rendered with this HOME rather than symlinked.
    LABEL=com.tony.sys-ram-watchdog
    AGENTS=~/Library/LaunchAgents
    PLIST="$AGENTS/$LABEL.plist"
    DOMAIN="gui/$(id -u)"
    mkdir -p "$AGENTS"
    NEW=$(sed "s|@HOME@|$HOME|g" "$BASE_DIR/launchd/$LABEL.plist")
    # Every launchctl failure below is a warning, not an abort: the tools are
    # already linked by now, only the daemon is missing.
    if [ -f "$PLIST" ] && [ "$(cat "$PLIST")" = "$NEW" ] \
        && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        # Same plist, already loaded → kick it so it runs the current code.
        launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 \
            && echo "   $LABEL already loaded — restarted (picks up new code)." \
            || echo "   $LABEL already loaded."
    else
        printf '%s\n' "$NEW" > "$PLIST"
        if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
            launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
            # bootout returns before launchd lets go; bootstrapping too early
            # fails with "5: Input/output error". Wait (≤5s) until it's gone.
            n=0
            while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && [ $n -lt 10 ]; do
                sleep 0.5; n=$((n + 1))
            done
        fi
        # bootstrap is the modern verb (retried — it can still race the
        # teardown); load -w for older macOS.
        ok=no
        for try in 1 2 3; do
            if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then ok=yes; break; fi
            if [ $try -lt 3 ]; then sleep 1; fi
        done
        [ $ok = yes ] || { launchctl load -w "$PLIST" 2>/dev/null && ok=yes; } || true
        if [ $ok = yes ]; then
            echo "   loaded $LABEL ($PLIST)"
        else
            echo "⚠️  couldn't load $LABEL — the tools are installed; load it by hand:"
            echo "    launchctl bootstrap $DOMAIN $PLIST"
        fi
    fi
    echo "ℹ️  skipped: gpu-switch + the diffusion vLLM unit — Linux/NVIDIA only."
    echo "    Ollama tuning on a Mac: launchd/README.md (com.tony.ollama-env)."
fi

echo "✅ Installed! Don't forget to create ~/.config/pushover.env"
