#!/usr/bin/env bash
# lib/platform.sh and the server tools that lean on it, on both OS branches.
# The macOS side runs here on Linux by forcing LLM_SUITE_OS=macos and stubbing
# sysctl / vm_stat / ollama on PATH; nvidia-smi is hidden so no real GPU leaks in.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"; mkdir -p "$STUB"

# A PATH with the stubs plus only the basics — no nvidia-smi, no ollama, no free.
BASIC="$TMP/basic"; mkdir -p "$BASIC"
for t in awk sed grep head tr cat dirname readlink uname basename mktemp rm sleep env; do
  p="$(command -v "$t")" && ln -s "$p" "$BASIC/$t"
done
ln -s "$BASH" "$BASIC/bash"   # same interpreter the suite runs under (3.2 on macOS CI)
NOGPU_PATH="$STUB:$BASIC"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$STUB/$1"; chmod +x "$STUB/$1"; }

# 36GB Mac, 16K pages: app = (500000-20000) + wired 300000 + compressed 100000 = 880000 pages
stub sysctl 'case "$2" in hw.memsize) echo 38654705664 ;; machdep.cpu.brand_string) echo "Apple M3 Pro" ;; esac'
stub vm_stat 'cat <<EOF
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               40000.
Pages active:                            600000.
Pages inactive:                          550000.
Pages wired down:                        300000.
Pages purgeable:                          20000.
File-backed pages:                       650000.
Anonymous pages:                         500000.
Pages occupied by compressor:            100000.
EOF'
stub ollama 'echo "NAME    ID    SIZE    PROCESSOR    UNTIL"'

mac() { ( export LLM_SUITE_OS=macos PATH="$NOGPU_PATH"; "$@" ); }
plat() { ( source "$REPO/lib/platform.sh"; "$@" ); }

eq "LLM_SUITE_OS forces the OS"           "macos" "$(LLM_SUITE_OS=macos plat plat_os)"
eq "macOS RAM from hw.memsize + vm_stat"  "13750 36864" "$(mac bash -c "source '$REPO/lib/platform.sh'; plat_mem_mib")"
eq "no nvidia-smi → no VRAM figure"       "" "$(mac bash -c "source '$REPO/lib/platform.sh'; plat_vram_mib")"

cat > "$TMP/meminfo" <<'EOF'
MemTotal:       527898112 kB
MemFree:        400000000 kB
MemAvailable:   500000000 kB
EOF
eq "Linux RAM from meminfo (total − available)" "27244 515525" \
   "$( ( export LLM_SUITE_OS=linux LLM_MEMINFO="$TMP/meminfo"; plat plat_mem_mib ) )"

# llm-status on a "Mac": derived banner, unified-memory note, nothing box-specific
OUT="$(mac "$REPO/bin/llm-status" 2>&1)"
ok       "llm-status runs on macOS"                    test -n "$OUT"
contains "llm-status derives the RAM total"            "$OUT" "(36GB Total)"
contains "llm-status shows the ollama ps table"        "$OUT" "PROCESSOR"
case "$OUT" in *512GB*|*"RTX 5000"*) _fail "llm-status has no hardcoded workstation banner" "$OUT" ;;
               *) _ok "llm-status has no hardcoded workstation banner" ;; esac
case "$OUT" in *"command not found"*) _fail "llm-status calls nothing missing on macOS" "$OUT" ;;
               *) _ok "llm-status calls nothing missing on macOS" ;; esac

# watchdog: one pass, RAM only (13750/36864 = 37%), no VRAM without nvidia-smi
eq "sys-ram-watchdog --once on macOS"   "RAM 37%" "$(mac "$REPO/bin/sys-ram-watchdog" --once 2>&1)"

# gpu-switch refuses cleanly on a Mac: one line, non-zero, touches nothing
GS="$(mac "$REPO/bin/gpu-switch" status 2>&1)"; rc=$?
ok       "gpu-switch exits non-zero on macOS" test "$rc" -ne 0
eq       "gpu-switch explains in one line"    "1" "$(printf '%s\n' "$GS" | wc -l | tr -d ' ')"
contains "gpu-switch says why"                "$GS" "Linux + NVIDIA only"

# …and on Linux without an NVIDIA card
GS="$( ( export LLM_SUITE_OS=linux PATH="$NOGPU_PATH"; "$REPO/bin/gpu-switch" ollama ) 2>&1)"; rc=$?
ok       "gpu-switch refuses on Linux without nvidia-smi" test "$rc" -ne 0
contains "…saying why"                                  "$GS" "Linux + NVIDIA only"

# The tools find lib/ through a symlink chain, as they do from ~/.local/bin
mkdir -p "$TMP/a" "$TMP/b"
ln -s "$REPO/bin/llm-status" "$TMP/a/llm-status"; ln -s "$TMP/a/llm-status" "$TMP/b/llm-status"
ok "llm-status runs through a two-hop symlink" mac "$TMP/b/llm-status"

finish
