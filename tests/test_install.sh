#!/usr/bin/env bash
# Battle-test install.sh from scratch into a throwaway HOME, with no GPU/systemd.
# Catches the class of bug where a new bin/ tool never gets linked (as gpu-switch
# once wasn't), and proves the install is idempotent. Both OS branches run here:
# LLM_SUITE_OS picks the branch, systemctl/launchctl are stubs that only log, so
# nothing real is ever enabled — on a Linux box or on the macOS CI runner.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"; mkdir -p "$STUB"

# systemctl: always fine. launchctl: remembers what's bootstrapped, so `print`
# answers like the real one and the idempotent path can be exercised.
cat > "$STUB/systemctl" <<'SH'
#!/usr/bin/env bash
echo "systemctl $*" >> "$HOME/.calls"
SH
cat > "$STUB/launchctl" <<'SH'
#!/usr/bin/env bash
echo "launchctl $*" >> "$HOME/.calls"
case "$1" in
  bootstrap) basename "$3" .plist >> "$HOME/.loaded" ;;
  bootout)   touch "$HOME/.loaded"; grep -vx "${2##*/}" "$HOME/.loaded" > "$HOME/.l2"; mv "$HOME/.l2" "$HOME/.loaded"; exit 0 ;;
  print)     grep -qx "${2##*/}" "$HOME/.loaded" 2>/dev/null ;;
esac
SH
chmod +x "$STUB/systemctl" "$STUB/launchctl"

# run_install OS HOME — output kept in HOME/.out for the "says what it skipped" checks
run_install() {
  mkdir -p "$2"
  ( export LLM_SUITE_OS="$1" HOME="$2" PATH="$STUB:$PATH"; "$BASH" "$REPO/install.sh" ) > "$2/.out" 2>&1
}

# ---------------- Linux branch ----------------
L="$TMP/linux"
run_install linux "$L"
ok "linux: install.sh exits 0" test $? -eq 0

# Every executable in bin/ must be symlinked into ~/.local/bin — no tool left behind.
missing=""
for b in "$REPO"/bin/*; do
  name="$(basename "$b")"
  [[ -x "$L/.local/bin/$name" ]] || missing+="$name "
done
eq "linux: every bin/ tool is linked into ~/.local/bin" "" "$missing"

# Links must point back into the repo (not copies that can drift).
eq "linux: gpu-switch link resolves into the repo" \
   "$REPO/bin/gpu-switch" "$(resolve_link "$L/.local/bin/gpu-switch")"

# The renderer must be reachable where install puts it.
ok "linux: master_setup_pi.sh linked into ~/.scripts" test -e "$L/.scripts/master_setup_pi.sh"

# llm-sync ships providers from ~/.scripts/providers; if install doesn't stage it,
# `compgen` silently skips and devcontainers never learn a new backend (diffusion).
ok "linux: providers/ staged for llm-sync in ~/.scripts" test -e "$L/.scripts/providers/diffusion.json"
eq "linux: providers staging resolves into the repo" \
   "$REPO/config/providers" "$(resolve_link "$L/.scripts/providers")"

ok "linux: watchdog unit linked"   test -e "$L/.config/systemd/user/sys-ram-watchdog.service"
contains "linux: watchdog enabled via systemd --user" "$(cat "$L/.calls")" "systemctl --user enable --now sys-ram-watchdog.service"
ok "linux: no launchd agent"       test ! -e "$L/Library/LaunchAgents"

# Idempotent: a second run must not error and must leave the same links.
run_install linux "$L"
ok "linux: idempotent (second run exits 0)" test $? -eq 0
ok "linux: gpu-switch still linked after re-run" test -x "$L/.local/bin/gpu-switch"

# No user bus (systemctl fails) must not abort the install under set -e.
NB="$TMP/nobus"; mkdir -p "$NB/stub"
printf '#!/usr/bin/env bash\nexit 1\n' > "$NB/stub/systemctl"; chmod +x "$NB/stub/systemctl"
( export LLM_SUITE_OS=linux HOME="$NB" PATH="$NB/stub:$STUB:$PATH"; "$BASH" "$REPO/install.sh" ) > "$NB/.out" 2>&1
ok       "linux: no systemd user bus is not fatal" test $? -eq 0
contains "linux: …and says so" "$(cat "$NB/.out")" "no systemd user bus"

# ---------------- macOS branch ----------------
M="$TMP/mac"
run_install macos "$M"
ok "macos: install.sh exits 0" test $? -eq 0

missing=""
for b in "$REPO"/bin/*; do
  name="$(basename "$b")"
  [[ "$name" == gpu-switch ]] && continue
  [[ -x "$M/.local/bin/$name" ]] || missing+="$name "
done
eq "macos: every portable tool is linked" "" "$missing"
ok "macos: gpu-switch NOT installed"       test ! -e "$M/.local/bin/gpu-switch"
contains "macos: says gpu-switch was skipped, and why" "$(cat "$M/.out")" "gpu-switch + the diffusion vLLM unit — Linux/NVIDIA only"
ok "macos: providers/ staged for llm-sync" test -e "$M/.scripts/providers/diffusion.json"
ok "macos: no systemd dir created"         test ! -e "$M/.config/systemd"
eq "macos: systemctl never called"         "0" "$(grep -c systemctl "$M/.calls")"

P="$M/Library/LaunchAgents/com.tony.sys-ram-watchdog.plist"
ok       "macos: watchdog LaunchAgent written" test -f "$P"
contains "macos: plist has HOME filled in" "$(cat "$P" 2>/dev/null)" "<string>$M/.local/bin/sys-ram-watchdog</string>"
eq       "macos: no @HOME@ placeholder left" "0" "$(grep -c @HOME@ "$P")"
contains "macos: loaded with launchctl bootstrap gui/<uid>" "$(cat "$M/.calls")" "launchctl bootstrap gui/$(id -u) $P"

# Idempotent: already loaded + unchanged → no second bootstrap.
run_install macos "$M"
ok "macos: idempotent (second run exits 0)" test $? -eq 0
eq "macos: re-run doesn't bootstrap again" "1" "$(grep -c 'launchctl bootstrap' "$M/.calls")"
contains "macos: …and says it's already loaded" "$(cat "$M/.out")" "already loaded"

# A changed plist (e.g. new HOME layout) is re-bootstrapped, not left stale.
echo "<!-- stale -->" >> "$P"
run_install macos "$M"
eq "macos: changed plist → bootout + bootstrap again" "2" "$(grep -c 'launchctl bootstrap' "$M/.calls")"

finish
