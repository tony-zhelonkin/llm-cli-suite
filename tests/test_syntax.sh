#!/usr/bin/env bash
# Every shipped script must parse (bash -n), and pass shellcheck if it's installed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# No mapfile — this suite runs under macOS's bash 3.2 too.
SCRIPTS=( "$REPO"/bin/* "$REPO"/lib/*.sh "$REPO"/config/master_setup_pi.sh
          "$REPO"/serving/diffusion/build-venv.sh "$REPO"/install.sh
          "$REPO"/tests/*.sh )

for s in "${SCRIPTS[@]}"; do
  [[ -f "$s" ]] || continue
  # $BASH: parse with the interpreter running the suite (3.2 under /bin/bash on a Mac)
  ok "bash -n $(basename "$s")" "$BASH" -n "$s"
done

SC="${SHELLCHECK:-shellcheck}"
if command -v "$SC" >/dev/null 2>&1; then
  for s in "${SCRIPTS[@]}"; do
    [[ -f "$s" ]] || continue
    # -e: don't fail the suite on style nits; gate only on error-level findings
    ok "shellcheck $(basename "$s")" "$SC" -S error "$s"
  done
else
  echo "  skip - shellcheck not installed (bash -n still ran)"
fi

finish
