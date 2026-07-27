#!/usr/bin/env bash
# Every shipped script must parse (bash -n), and pass shellcheck if it's installed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mapfile -t SCRIPTS < <(
  printf '%s\n' "$REPO"/bin/* "$REPO"/config/master_setup_pi.sh \
                "$REPO"/serving/diffusion/build-venv.sh "$REPO"/install.sh \
                "$REPO"/tests/*.sh
)

for s in "${SCRIPTS[@]}"; do
  [[ -f "$s" ]] || continue
  ok "bash -n $(basename "$s")" bash -n "$s"
done

if command -v shellcheck >/dev/null 2>&1; then
  for s in "${SCRIPTS[@]}"; do
    [[ -f "$s" ]] || continue
    # -e: don't fail the suite on style nits; gate only on error-level findings
    ok "shellcheck $(basename "$s")" shellcheck -S error "$s"
  done
else
  echo "  skip - shellcheck not installed (bash -n still ran)"
fi

finish
