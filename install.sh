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
    mkdir -p ~/.config/systemd/user
    ln -sf "$BASE_DIR/systemd/sys-ram-watchdog.service" ~/.config/systemd/user/sys-ram-watchdog.service
    if systemctl --user daemon-reload 2>/dev/null; then
        systemctl --user enable --now sys-ram-watchdog.service
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
    if [ -f "$PLIST" ] && [ "$(cat "$PLIST")" = "$NEW" ] \
        && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        echo "   $LABEL already loaded."
    else
        printf '%s\n' "$NEW" > "$PLIST"
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        # bootstrap is the modern verb; load -w for older macOS.
        launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
        echo "   loaded $LABEL ($PLIST)"
    fi
    echo "ℹ️  skipped: gpu-switch + the diffusion vLLM unit — Linux/NVIDIA only."
    echo "    Ollama tuning on a Mac: launchd/README.md (com.tony.ollama-env)."
fi

echo "✅ Installed! Don't forget to create ~/.config/pushover.env"
