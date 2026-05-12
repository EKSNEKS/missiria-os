#!/bin/bash

# ── Install all batch scripts as global commands in /usr/local/bin ────────────
# Creates symlinks without .sh extension so you can run e.g. `url-checker`

set -uo pipefail

if [ "$EUID" -ne 0 ]; then echo "❌ Run as root." >&2; exit 1; fi

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'; BOLD='\033[1m'

BATCHES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"

echo ""
echo -e "${BOLD}Installing batch scripts → ${BIN_DIR}${NC}"
echo ""

INSTALLED=0; UPDATED=0; SKIPPED=0

for script in "${BATCHES_DIR}"/*.sh; do
    filename=$(basename "$script")

    # Skip this installer itself
    [[ "$filename" == "install-batches.sh" ]] && continue

    # Strip .sh → command name
    cmd="${filename%.sh}"

    # Ensure script is executable
    chmod +x "$script"

    target="${BIN_DIR}/${cmd}"

    if [ -L "$target" ]; then
        old_link=$(readlink "$target")
        if [ "$old_link" == "$script" ]; then
            printf "  ${YELLOW}[skip]${NC}    %-30s already linked\n" "$cmd"
            ((SKIPPED++))
            continue
        else
            # Update stale symlink
            ln -sf "$script" "$target"
            printf "  ${YELLOW}[updated]${NC} %-30s → %s\n" "$cmd" "$script"
            ((UPDATED++))
        fi
    elif [ -e "$target" ]; then
        # Real file exists (not a symlink) — don't overwrite
        printf "  ${RED}[skip]${NC}    %-30s conflict: real file exists at %s\n" "$cmd" "$target"
        ((SKIPPED++))
    else
        ln -s "$script" "$target"
        printf "  ${GREEN}[installed]${NC} %-30s → %s\n" "$cmd" "$script"
        ((INSTALLED++))
    fi
done

echo ""
echo -e "  Installed : ${GREEN}${BOLD}${INSTALLED}${NC}"
echo -e "  Updated   : ${YELLOW}${BOLD}${UPDATED}${NC}"
echo -e "  Skipped   : ${SKIPPED}"
echo ""
echo -e "${GREEN}Done. Commands available system-wide.${NC}"
echo ""
echo -e "Available commands:"
for script in "${BATCHES_DIR}"/*.sh; do
    filename=$(basename "$script")
    [[ "$filename" == "install-batches.sh" ]] && continue
    echo "  ${filename%.sh}"
done
echo ""
