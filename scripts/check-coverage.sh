#!/usr/bin/env bash
# Builds and runs the host test suite (tests/) with gcov instrumentation,
# reports line coverage for components/*/src/, and fails if it's below
# MIN_COVERAGE.
#
# Scope: this only covers components/ code reachable from tests/ -- i.e.
# the hardware-independent logic (control_math and anything added beside
# it). main/*.cpp and anything that only runs on-device isn't included:
# there's no practical way to collect gcov data from real hardware or a
# board-less run of ESP-IDF-dependent code here. That's the whole reason
# control_math is split out the way it is -- put joint-level math there
# (not in main.cpp) if you want it covered by this.
#
# Usage: scripts/check-coverage.sh [min-coverage-percent]
# Env: CHECK_COVERAGE_BUILD_DIR (default: build-coverage)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_COVERAGE="${1:-80}"
BUILD_DIR="${CHECK_COVERAGE_BUILD_DIR:-$ROOT_DIR/build-coverage}"

for tool in cmake ninja gcovr; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool not found in PATH." >&2
        exit 127
    fi
done

# A dedicated build dir, separate from the normal build-tests/: coverage
# flags (--coverage -O0) shouldn't silently leak into a non-coverage build
# someone forgot to reconfigure, and vice versa.
cmake -S "$ROOT_DIR/tests" -B "$BUILD_DIR" -G Ninja -DENABLE_COVERAGE=ON >/dev/null
cmake --build "$BUILD_DIR" >/dev/null
ctest --test-dir "$BUILD_DIR" --output-on-failure

echo "-- coverage (components/*/src/, from tests/) --"
gcovr --root "$ROOT_DIR" \
    --filter 'components/.*/src/.*' \
    --exclude '.*/tests/.*' \
    --print-summary \
    --fail-under-line "$MIN_COVERAGE" \
    "$BUILD_DIR"
