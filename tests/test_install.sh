#!/usr/bin/env bash
# Battle-test install.sh from scratch into a throwaway HOME, with no GPU/systemd.
# Catches the class of bug where a new bin/ tool never gets linked (as gpu-switch
# once wasn't), and proves the install is idempotent. Both OS branches run here:
# LLM_SUITE_OS picks the branch, systemctl/launchctl are stubs that only log, so
# nothing real is ever enabled — on a Linux box or on the macOS CI runner.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"; mkdir -p "$STUB"

# systemctl: succeeds, and remembers whether the unit is running (is-active).
# launchctl: remembers what's bootstrapped, so `print` answers like the real one.
# Knobs, as files in the fake HOME:
#   .bootstrap_fail N  the next N bootstraps fail (the "5: I/O error" race)
#   .bootout_lag N     after bootout, `print` still sees the job N more times
#   .load_fail         `load -w` fails too
cat > "$STUB/systemctl" <<'SH'
#!/usr/bin/env bash
echo "systemctl $*" >> "$HOME/.calls"
case "$*" in
  *is-active*) [ -f "$HOME/.active" ] ;;
  *"enable --now"*|*restart*) touch "$HOME/.active" ;;
esac
SH
cat > "$STUB/launchctl" <<'SH'
#!/usr/bin/env bash
echo "launchctl $*" >> "$HOME/.calls"
n() { cat "$HOME/$1" 2>/dev/null || echo 0; }
case "$1" in
  bootstrap)
    if [ "$(n .bootstrap_fail)" -gt 0 ]; then
      echo $(( $(n .bootstrap_fail) - 1 )) > "$HOME/.bootstrap_fail"
      echo "Bootstrap failed: 5: Input/output error" >&2; exit 5
    fi
    basename "$3" .plist >> "$HOME/.loaded" ;;
  bootout)
    touch "$HOME/.loaded"; grep -vx "${2##*/}" "$HOME/.loaded" > "$HOME/.l2"; mv "$HOME/.l2" "$HOME/.loaded"
    [ -f "$HOME/.bootout_lag" ] && cp "$HOME/.bootout_lag" "$HOME/.lag"; exit 0 ;;
  print)
    if [ "$(n .lag)" -gt 0 ]; then echo $(( $(n .lag) - 1 )) > "$HOME/.lag"; exit 0; fi
    grep -qx "${2##*/}" "$HOME/.loaded" 2>/dev/null ;;
  load) [ ! -f "$HOME/.load_fail" ] ;;
  kickstart) exit 0 ;;
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
eq       "linux: first install doesn't restart" "0" "$(grep -c 'restart' "$L/.calls")"
ok "linux: no launchd agent"       test ! -e "$L/Library/LaunchAgents"

# Idempotent: a second run must not error and must leave the same links.
run_install linux "$L"
ok "linux: idempotent (second run exits 0)" test $? -eq 0
ok "linux: gpu-switch still linked after re-run" test -x "$L/.local/bin/gpu-switch"
# …and the watchdog, already active, is restarted so it runs the new code
contains "linux: re-install restarts the running watchdog" "$(cat "$L/.calls")" "systemctl --user restart sys-ram-watchdog.service"
contains "linux: …and says so" "$(cat "$L/.out")" "restarted sys-ram-watchdog.service"

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
contains "macos: …and kickstarts it to run the new code" "$(cat "$M/.calls")" "launchctl kickstart -k gui/$(id -u)/com.tony.sys-ram-watchdog"

# A changed plist (e.g. new HOME layout) is re-bootstrapped, not left stale.
echo "<!-- stale -->" >> "$P"
run_install macos "$M"
eq "macos: changed plist → bootout + bootstrap again" "2" "$(grep -c 'launchctl bootstrap' "$M/.calls")"

# bootout is async: launchd still lists the job for a moment. The installer must
# wait it out before bootstrapping, not race it.
echo "<!-- stale again -->" >> "$P"; echo 3 > "$M/.bootout_lag"; : > "$M/.calls"
run_install macos "$M"
ok "macos: lagging bootout → still exits 0" test $? -eq 0
after_bootout="$(sed -n '/launchctl bootout/,$p' "$M/.calls")"
eq "macos: waited — print polled until the job was gone" "4" \
   "$(printf '%s\n' "$after_bootout" | sed '/launchctl bootstrap/,$d' | grep -c 'launchctl print')"
eq "macos: …then one clean bootstrap" "1" "$(grep -c 'launchctl bootstrap' "$M/.calls")"
rm -f "$M/.bootout_lag"

# First bootstrap fails (the "5: Input/output error" race) → retried, loaded.
F="$TMP/mac-flaky"; mkdir -p "$F"; echo 1 > "$F/.bootstrap_fail"
run_install macos "$F"
ok       "macos: first bootstrap fails → install still exits 0" test $? -eq 0
eq       "macos: …bootstrap retried" "2" "$(grep -c 'launchctl bootstrap' "$F/.calls")"
contains "macos: …and loaded on the retry" "$(cat "$F/.out")" "loaded com.tony.sys-ram-watchdog"

# launchd refuses outright (bootstrap and load -w) → a warning, never an abort.
X="$TMP/mac-broken"; mkdir -p "$X"; echo 99 > "$X/.bootstrap_fail"; touch "$X/.load_fail"
run_install macos "$X"
ok       "macos: launchd failing is not fatal under set -e" test $? -eq 0
contains "macos: …warns how to load it by hand" "$(cat "$X/.out")" "couldn't load com.tony.sys-ram-watchdog"
ok       "macos: …and the tools are still linked" test -x "$X/.local/bin/llm-status"
contains "macos: …and the installer still finishes" "$(cat "$X/.out")" "Installed!"

finish
