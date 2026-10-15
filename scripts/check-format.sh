#!/usr/bin/env bash
# Fails if any main/, components/, or tests/ file is not clang-format clean.
# Covers every C/C++ source and header extension, not just .cpp/.hpp, so a
# stray .h or .c file can't slip past unchecked.
# Usage: scripts/check-format.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v clang-format >/dev/null 2>&1; then
    echo "clang-format not found in PATH." >&2
    exit 127
fi

# tests/ is flat by design (see check-tidy.sh), and -maxdepth 1 keeps a
# build dir configured inside it (e.g. `cmake -S tests -B tests/build`)
# from dragging googletest's sources into the check.
mapfile -t FILES < <(
    {
        find "$ROOT_DIR/main" "$ROOT_DIR/components" -type f
        find "$ROOT_DIR/tests" -maxdepth 1 -type f
    } | grep -E '\.(c|cc|cpp|cxx|h|hh|hpp|hxx)$' | sort
)

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "No main/components/tests files found to format-check."
    exit 0
fi

clang-format --dry-run --Werror "${FILES[@]}"
