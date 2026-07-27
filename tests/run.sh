#!/usr/bin/env bash
# Run every tests/test_*.sh. Exit non-zero if any test fails. This is what CI runs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
for t in "$HERE"/test_*.sh; do
  echo "== $(basename "$t") =="
  bash "$t" || fail=1
  echo
done

if [[ "$fail" -eq 0 ]]; then
  echo "ALL SUITES PASSED"
else
  echo "SOME SUITES FAILED" >&2
fi
exit "$fail"
