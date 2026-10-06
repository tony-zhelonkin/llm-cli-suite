#!/usr/bin/env bash
# Static check: no Linux-/bash-4-isms in code a Mac can reach. macOS ships bash
# 3.2 and BSD userland, so these either don't exist or behave differently there.
# A line that really is Linux-only (inside an OS branch) carries `# linux-only`.
# gpu-switch and the CUDA venv builder are Linux/NVIDIA by design — not scanned.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELF="$(basename "${BASH_SOURCE[0]}")"
FILES=""
for f in "$REPO"/bin/* "$REPO"/lib/*.sh "$REPO"/install.sh "$REPO"/config/master_setup_pi.sh "$REPO"/tests/*.sh; do
  case "$(basename "$f")" in gpu-switch|"$SELF") continue ;; esac
  FILES="$FILES $f"
done

# pattern|why — POSIX extended regexes (no \b: BSD grep), matched against non-comment lines
RULES='(^|[^[:alnum:]_-])(mapfile|readarray)([^[:alnum:]_-]|$)|bash 4 builtin
declare -[a-zA-Z]*A|associative arrays are bash 4
(local|declare) -n|namerefs are bash 4.3
\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|case-modifying expansion is bash 4
&>>|append-both redirect is bash 4
(^|[^[:alnum:]_-])sed -i( |$)|BSD sed -i needs a suffix (use -i.bak)
(^|[^[:alnum:]_-])stat -c|GNU stat; BSD uses -f
(^|[^[:alnum:]_-])date -d|GNU date; BSD uses -j -f
(^|[^[:alnum:]_-])readlink -f|not on older macOS; walk the link with readlink
-printf|GNU find only
(^|[^[:alnum:]_-])grep -[a-zA-Z]*P|PCRE grep is GNU only
(^|[;&|(]|\$\()[[:space:]]*timeout |no timeout(1) on macOS
(^|[^[:alnum:]_-])numfmt([^[:alnum:]_-]|$)|GNU coreutils only
(^|[;&|(]|\$\()[[:space:]]*free( |$)|no free(1) on macOS
(^|[^[:alnum:]_-])nproc([^[:alnum:]_-]|$)|GNU coreutils only (sysctl -n hw.ncpu on mac)
/proc/|no /proc on macOS
(^|[^[:alnum:]_-])getent([^[:alnum:]_-]|$)|not on macOS'

while IFS= read -r rule; do
  pat="${rule%|*}"; why="${rule##*|}"
  # shellcheck disable=SC2086
  hits="$(grep -nE -e "$pat" $FILES 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' | grep -v '# linux-only' || true)"
  if [[ -z "$hits" ]]; then _ok "no ${pat} ($why)"; else _fail "found ${pat} — $why" "$hits"; fi
done <<< "$RULES"

finish
