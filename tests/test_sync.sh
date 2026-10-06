#!/usr/bin/env bash
# llm-sync against throwaway project trees: LLM_SYNC_ROOTS picks the roots
# (colon or space separated), missing roots are skipped, and each devcontainer
# gets setup_pi.sh with providers/ beside it.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; mkdir -p "$H/.scripts" "$TMP/ws1/proj-a/.devcontainer" "$TMP/ws2/group/proj-b/.devcontainer"
ln -s "$REPO/config/master_setup_pi.sh" "$H/.scripts/master_setup_pi.sh"
ln -s "$REPO/config/providers" "$H/.scripts/providers"

sync() { ( export HOME="$H" LLM_SYNC_ROOTS="$1"; "$REPO/bin/llm-sync" ) 2>&1; }

OUT="$(sync "$TMP/ws1:$TMP/does-not-exist $TMP/ws2")"
ok       "llm-sync exits 0 with a missing root in the list" test $? -eq 0
contains "found both projects across both separators" "$OUT" "to 2 projects"
ok "setup_pi.sh shipped into ws1 (colon-separated)" test -f "$TMP/ws1/proj-a/.devcontainer/scripts/setup_pi.sh"
ok "setup_pi.sh shipped into ws2 (space-separated)" test -f "$TMP/ws2/group/proj-b/.devcontainer/scripts/setup_pi.sh"
ok "providers/ shipped beside it"                  test -f "$TMP/ws2/group/proj-b/.devcontainer/scripts/providers/diffusion.json"
ok "shipped as a real file, not a symlink (Docker can't follow those)" \
   test ! -L "$TMP/ws1/proj-a/.devcontainer/scripts/setup_pi.sh"

OUT="$(sync "$TMP/nothing-here")"
contains "no roots found → says so, exits clean" "$OUT" "No Devcontainers found"

# The shipped copy must still render on its own, as it does inside a container.
SH="$TMP/ws1/proj-a/.devcontainer/scripts"
eq "shipped setup_pi.sh renders from its own providers/" "http://172.17.0.1:11434/v1" \
   "$( ( unset OLLAMA_HOST DIFFUSION_HOST LLM_AGENT_ENV; source "$SH/setup_pi.sh" && render_pi_models "$SH/providers" /dev/stdout ) | jq -r '.providers.ollama.baseUrl')"

finish
