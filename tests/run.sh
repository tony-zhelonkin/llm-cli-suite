#!/usr/bin/env bash
# Run every tests/test_*.sh. Exit non-zero if any test fails. This is what CI runs.
# SHELLCHECK overrides which shellcheck test_syntax uses (e.g. a downloaded binary).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
for t in "$HERE"/test_*.sh; do
  echo "== $(basename "$t") =="
  # Same interpreter as this runner, so `/bin/bash tests/run.sh` on a Mac really
  # exercises bash 3.2 all the way down.
  "$BASH" "$t" || fail=1
  echo
done

if [[ "$fail" -eq 0 ]]; then
  echo "ALL SUITES PASSED"
else
  echo "SOME SUITES FAILED" >&2
fi
exit "$fail"
