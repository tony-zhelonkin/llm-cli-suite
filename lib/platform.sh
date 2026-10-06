# platform.sh — the few facts the server-side tools need about the box they run on.
# Sourced, not executed. Bash 3.2 / BSD-safe on purpose: macOS ships bash 3.2,
# no /proc, no `free`, no nvidia-smi.
#
#   plat_os        → linux | macos            (LLM_SUITE_OS overrides, for tests)
#   plat_accel     → nvidia | metal | none
#   plat_mem_mib   → "USED TOTAL" in MiB (RAM; on a Mac that's the unified pool)
#   plat_vram_mib  → "USED TOTAL" in MiB for GPU 0, or nothing without nvidia-smi
#
# Tools find this file by walking their own ~/.local/bin symlink with plain
# `readlink` in a loop — old macOS has no `readlink -f`.
# shellcheck shell=bash

plat_os() {
    if [ -n "${LLM_SUITE_OS:-}" ]; then echo "$LLM_SUITE_OS"; return; fi
    case "$(uname -s)" in
        Darwin) echo macos ;;
        *)      echo linux ;;
    esac
}

plat_accel() {
    if command -v nvidia-smi >/dev/null 2>&1; then echo nvidia; return; fi
    if [ "$(plat_os)" = macos ] && [ "$(uname -m)" = arm64 ]; then echo metal; return; fi
    echo none
}

plat_mem_mib() {
    if [ "$(plat_os)" = macos ]; then
        # Activity Monitor's "Memory Used" ≈ app (anonymous − purgeable) + wired +
        # compressed. Page size comes from vm_stat's own header (16K on Apple Silicon).
        local total
        total=$(( $(sysctl -n hw.memsize) / 1048576 ))
        vm_stat | awk -v total="$total" '
            /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i+1) }
            { v = $NF; gsub(/\./, "", v) }
            /^Anonymous pages/              { anon = v }
            /^Pages active/                 { active = v }
            /^Pages purgeable/              { purg = v }
            /^Pages wired down/             { wired = v }
            /^Pages occupied by compressor/ { comp = v }
            END {
                app = (anon != "" ? anon : active) - purg
                printf "%d %d\n", (app + wired + comp) * ps / 1048576, total
            }'
    else
        # used = total − available. Stricter than `free`'s "used": shm/tmpfs
        # sits in buff/cache there but can't be reclaimed under pressure.
        awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2}
             END { printf "%d %d\n", (t - a) / 1024, t / 1024 }' "${LLM_MEMINFO:-/proc/meminfo}"
    fi
}

plat_vram_mib() {
    command -v nvidia-smi >/dev/null 2>&1 || return 0
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits \
        | head -1 | tr -d ' ' | tr ',' ' '
}
