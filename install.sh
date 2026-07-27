#!/bin/bash
# Installer for the LLM Workstation Tools

echo "Setting up LLM Workstation Tools..."

# Ensure directories exist
mkdir -p ~/.local/bin
mkdir -p ~/.scripts
mkdir -p ~/.config/systemd/user

# Create symlinks
BASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ln -sf "$BASE_DIR/bin/sys-notify" ~/.local/bin/sys-notify
ln -sf "$BASE_DIR/bin/llm-manage" ~/.local/bin/llm-manage
ln -sf "$BASE_DIR/bin/llm-status" ~/.local/bin/llm-status
ln -sf "$BASE_DIR/bin/llm-sync" ~/.local/bin/llm-sync
ln -sf "$BASE_DIR/bin/gpu-switch" ~/.local/bin/gpu-switch
ln -sf "$BASE_DIR/bin/sys-ram-watchdog" ~/.local/bin/sys-ram-watchdog
ln -sf "$BASE_DIR/config/master_setup_pi.sh" ~/.scripts/master_setup_pi.sh
ln -sf "$BASE_DIR/systemd/sys-ram-watchdog.service" ~/.config/systemd/user/sys-ram-watchdog.service

# Setup Systemd
systemctl --user daemon-reload
systemctl --user enable --now sys-ram-watchdog.service

echo "✅ Installed! Don t forget to create ~/.config/pushover.env"
