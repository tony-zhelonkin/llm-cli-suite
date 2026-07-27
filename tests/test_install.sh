#!/usr/bin/env bash
# Battle-test install.sh from scratch into a throwaway HOME, with no GPU/systemd.
# Catches the class of bug where a new bin/ tool never gets linked (as gpu-switch
# once wasn't), and proves the install is idempotent.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE"' EXIT

# Run install.sh with HOME redirected and systemctl stubbed (no user bus in CI).
run_install() {
  local stub="$FAKE/stub"; mkdir -p "$stub"
  cat > "$stub/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$stub/systemctl"
  ( export HOME="$FAKE" PATH="$stub:$PATH"; bash "$REPO/install.sh" ) >/dev/null 2>&1
}

run_install
ok "install.sh exits 0" test $? -eq 0

# Every executable in bin/ must be symlinked into ~/.local/bin — no tool left behind.
missing=""
for b in "$REPO"/bin/*; do
  name="$(basename "$b")"
  [[ -x "$FAKE/.local/bin/$name" ]] || missing+="$name "
done
eq "every bin/ tool is linked into ~/.local/bin" "" "$missing"

# Links must point back into the repo (not copies that can drift).
eq "gpu-switch link resolves into the repo" \
   "$REPO/bin/gpu-switch" "$(readlink -f "$FAKE/.local/bin/gpu-switch" 2>/dev/null)"

# The renderer must be reachable where install puts it.
ok "master_setup_pi.sh linked into ~/.scripts" test -e "$FAKE/.scripts/master_setup_pi.sh"

# llm-sync ships providers from ~/.scripts/providers; if install doesn't stage it,
# `compgen` silently skips and devcontainers never learn a new backend (diffusion).
ok "providers/ staged for llm-sync in ~/.scripts" test -e "$FAKE/.scripts/providers/diffusion.json"
eq "providers staging resolves into the repo" \
   "$REPO/config/providers" "$(readlink -f "$FAKE/.scripts/providers" 2>/dev/null)"

# Idempotent: a second run must not error and must leave the same links.
run_install
ok "install.sh is idempotent (second run exits 0)" test $? -eq 0
ok "gpu-switch still linked after re-run" test -x "$FAKE/.local/bin/gpu-switch"

finish
