#!/usr/bin/env bash
# Fails if any main/ or components/ file is not clang-format clean.
# Usage: scripts/check-format.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v clang-format >/dev/null 2>&1; then
    echo "clang-format not found in PATH." >&2
    exit 127
fi

mapfile -t FILES < <(find "$ROOT_DIR/main" "$ROOT_DIR/components" -type f \( -name '*.cpp' -o -name '*.hpp' \) | sort)

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "No main/components files found to format-check."
    exit 0
fi

clang-format --dry-run --Werror "${FILES[@]}"
