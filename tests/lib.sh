# Tiny test harness — sourced by each tests/test_*.sh.
# No dependencies beyond bash + coreutils. Tracks pass/fail, prints TAP-ish lines.
# Bash 3.2 / BSD-safe: CI runs it under macOS's stock /bin/bash too.
# shellcheck shell=bash
set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TESTS_PASS:=0}" "${TESTS_FAIL:=0}"

_ok()   { TESTS_PASS=$((TESTS_PASS+1)); echo "  ok   - $1"; }
_fail() { TESTS_FAIL=$((TESTS_FAIL+1)); echo "  FAIL - $1"; [[ -n "${2:-}" ]] && echo "         $2"; }

# ok "desc" <cmd...>  — passes if cmd exits 0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then _ok "$d"; else _fail "$d" "cmd: $*"; fi; }

# eq "desc" EXPECTED ACTUAL
eq() { if [[ "$2" == "$3" ]]; then _ok "$1"; else _fail "$1" "expected [$2] got [$3]"; fi; }

# contains "desc" HAYSTACK NEEDLE
contains() { if [[ "$2" == *"$3"* ]]; then _ok "$1"; else _fail "$1" "[$2] lacks [$3]"; fi; }

# resolve_link PATH — where a symlink chain ends up (portable `readlink -f`).
resolve_link() {
  local f="$1" d
  while [[ -L "$f" ]]; do
    d="$(cd -P "$(dirname "$f")" && pwd)"; f="$(readlink "$f")"
    [[ "$f" == /* ]] || f="$d/$f"
  done
  if [[ -d "$f" ]]; then (cd -P "$f" && pwd); else echo "$(cd -P "$(dirname "$f")" && pwd)/$(basename "$f")"; fi
}

finish() {
  echo "----"
  echo "$(basename "${0}"): $TESTS_PASS passed, $TESTS_FAIL failed"
  [[ "$TESTS_FAIL" -eq 0 ]]
}
