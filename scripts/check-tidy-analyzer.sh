#!/usr/bin/env bash
# Runs the Clang Static Analyzer checks (.clang-tidy-analyzer) in isolation
# from scripts/check-tidy.sh's main AST-matcher lint pass.
#
# Why a separate script rather than a flag on check-tidy.sh: the analyzer
# is symbolic execution, not a lexical/AST-matcher pass -- far more
# expensive per translation unit than every other clang-tidy check
# combined. Keeping it as its own executable means it gets its own cache
# (an ordinary .clang-tidy edit doesn't invalidate analyzer results, and
# vice versa) and its own CI job, so the fast routine lint and the slow
# analyzer pass never block or invalidate each other. See
# .clang-tidy-analyzer for why this checker subset specifically.
#
# Mirrors check-tidy.sh's translation-unit discovery, dual build
# directories, fingerprint cache, and parallel-execution model; see that
# script's comments for the reasoning behind each. Does NOT repeat
# check-tidy.sh's orphaned-header invariant check -- that enforces
# coverage (every header reachable from a real TU), already asserted once
# by the main script, and this script analyzes the exact same TU list so
# there's nothing more to enforce here.
#
# Usage: scripts/check-tidy-analyzer.sh [firmware-build-dir] [tests-build-dir]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-$ROOT_DIR/build}"
TESTS_BUILD_DIR="${2:-$ROOT_DIR/build-tests}"
COMPILE_DB="$BUILD_DIR/compile_commands.json"
TESTS_COMPILE_DB="$TESTS_BUILD_DIR/compile_commands.json"
CACHE_FILE="$BUILD_DIR/.check-tidy-analyzer-cache"
CONFIG_FILE="$ROOT_DIR/.clang-tidy-analyzer"
FLAGS_HELPER="$ROOT_DIR/scripts/_compile_flags_for.py"
CLANG_DB_HELPER="$ROOT_DIR/scripts/_clang_compile_db.py"

if ! command -v clang-tidy >/dev/null 2>&1; then
    echo "clang-tidy not found in PATH." >&2
    exit 127
fi

if [ ! -f "$COMPILE_DB" ]; then
    echo "compile_commands.json not found at $COMPILE_DB -- run 'idf.py build' first." >&2
    exit 1
fi

RUN_TESTS=1
if [ ! -f "$TESTS_COMPILE_DB" ]; then
    echo "warning: $TESTS_COMPILE_DB not found -- skipping tests/ (run" \
         "'cmake -S tests -B $TESTS_BUILD_DIR' first to include it)." >&2
    RUN_TESTS=0
fi

# Unlike check-tidy.sh, there's no src-vs-tests config split to worry about
# here: --config-file below pins every TU to the exact same analyzer
# config regardless of directory, so one header filter covers all of them.
HEADER_FILTER="^${ROOT_DIR}/(main|components|tests)/.*"

# Hashes .clang-tidy-analyzer and this script (and its flags helper), so a
# config or flag change invalidates every cache entry at once, the same as
# a source edit would. Deliberately independent of check-tidy.sh's own
# CONFIG_HASH (its .clang-tidy / tests/.clang-tidy inputs) -- the two
# caches don't share invalidation triggers, since neither run's outcome
# depends on the other's config.
CONFIG_HASH="$(cat "$CONFIG_FILE" "$FLAGS_HELPER" "$CLANG_DB_HELPER" "${BASH_SOURCE[0]}" | sha256sum | awk '{print $1}')"

# See check-tidy.sh for the reasoning behind this (exact, via each file's
# own compiler and flags, rather than a hardcoded list).
project_deps_of() {
    local file="$1" db="$2"
    local parts
    mapfile -d '' -t parts < <(python3 "$FLAGS_HELPER" "$db" "$file" 2>/dev/null) || true
    if [ "${#parts[@]}" -lt 2 ]; then
        return 0
    fi

    local directory="${parts[0]}"
    local args=("${parts[@]:1}")
    local compiler="${args[0]}"
    local m_args=() skip_next=0 a
    for ((i = 1; i < ${#args[@]}; i++)); do
        a="${args[$i]}"
        if [ "$skip_next" = "1" ]; then
            skip_next=0
            continue
        fi
        case "$a" in
            -c) continue ;;
            -o) skip_next=1; continue ;;
        esac
        [ "$a" = "$file" ] && continue
        m_args+=("$a")
    done

    (cd "$directory" && "$compiler" "${m_args[@]}" -M "$file" 2>/dev/null) \
        | sed 's/^[^:]*://' \
        | tr -d '\\' \
        | tr -s ' \t\n' '\n' \
        | sed '/^$/d' \
        | { grep -E "^${ROOT_DIR}/(main|components|tests)/" || true; } \
        | xargs -r readlink -f \
        | sort -u
}

fingerprint_of() {
    {
        echo "$CONFIG_HASH"
        project_deps_of "$1" "$2" | xargs -r sha256sum
    } | sha256sum | awk '{print $1}'
}

declare -A CACHE
if [ -f "$CACHE_FILE" ]; then
    while IFS=$'\t' read -r unit hash; do
        [ -n "$unit" ] && CACHE["$unit"]="$hash"
    done < "$CACHE_FILE"
fi
declare -A NEW_CACHE

STATUS=0
JOBS="${CHECK_TIDY_JOBS:-$(nproc 2>/dev/null || echo 4)}"
# A fresh, unique directory per invocation -- see check-tidy.sh's identical
# comment for why a fixed name under $BUILD_DIR isn't safe here.
RESULT_DIR="$(mktemp -d "$BUILD_DIR/.check-tidy-analyzer-parallel.XXXXXX")"
trap 'rm -rf "$RESULT_DIR"' EXIT

# clang-tidy can't read the firmware compile database as-is (it's recorded
# for the xtensa cross gcc) -- lint firmware TUs against a clang-compatible
# copy instead; see $CLANG_DB_HELPER. Fingerprinting keeps using the
# original, since its `-M` scan runs the real gcc.
FIRMWARE_TIDY_DB="$RESULT_DIR/firmware-db"
python3 "$CLANG_DB_HELPER" "$COMPILE_DB" "$FIRMWARE_TIDY_DB"

mapfile -t MAIN_FILES < <(find "$ROOT_DIR/main" -maxdepth 1 -name '*.cpp' | sort)
mapfile -t COMPONENT_FILES < <(find "$ROOT_DIR/components" -mindepth 2 -maxdepth 2 -path '*/src' -type d \
    -exec find {} -maxdepth 1 -name '*.cpp' \; 2>/dev/null | sort)
SRC_FILES=("${MAIN_FILES[@]}" "${COMPONENT_FILES[@]}")

TEST_FILES=()
if [ "$RUN_TESTS" = "1" ]; then
    mapfile -t TEST_FILES < <(find "$ROOT_DIR/tests" -maxdepth 1 -name '*.cpp' | sort)
fi

ALL_UNITS=() ALL_DBS=()
for src in "${SRC_FILES[@]}"; do
    ALL_UNITS+=("$src"); ALL_DBS+=("$BUILD_DIR")
done
for test_src in "${TEST_FILES[@]}"; do
    ALL_UNITS+=("$test_src"); ALL_DBS+=("$TESTS_BUILD_DIR")
done

# Phase 1: resolve which units are already cached as passing (cheap -- no
# clang-tidy invocation involved) versus which actually need to be checked.
TO_RUN_FILES=() TO_RUN_DBS=() TO_RUN_FPS=()
SKIPPED_COUNT=0
for i in "${!ALL_UNITS[@]}"; do
    file="${ALL_UNITS[$i]}"
    db="${ALL_DBS[$i]}/compile_commands.json"
    rel="${file#"$ROOT_DIR"/}"
    fp="$(fingerprint_of "$file" "$db")"

    if [ "${CACHE[$rel]:-}" = "$fp" ]; then
        NEW_CACHE["$rel"]="$fp"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    TO_RUN_FILES+=("$file")
    if [ "${ALL_DBS[$i]}" = "$BUILD_DIR" ]; then
        TO_RUN_DBS+=("$FIRMWARE_TIDY_DB")
    else
        TO_RUN_DBS+=("${ALL_DBS[$i]}")
    fi
    TO_RUN_FPS+=("$fp")
done
CHECKED_COUNT="${#TO_RUN_FILES[@]}"

# Phase 2: run the actual clang-tidy invocations, up to JOBS concurrently.
# See check-tidy.sh for why results are buffered per-file and printed back
# in order, and why the invocation is wrapped in `|| rc=$?` rather than
# checked via a bare `if` after the fact.
run_check() {
    local file="$1" build_dir="$2" idx="$3"
    local rc=0
    clang-tidy -p "$build_dir" --quiet \
        --config-file="$CONFIG_FILE" \
        --header-filter="$HEADER_FILTER" \
        --warnings-as-errors='*' \
        "$file" > "$RESULT_DIR/$idx.log" 2>&1 || rc=$?
    echo "$rc" > "$RESULT_DIR/$idx.status"
}

if [ "${#TO_RUN_FILES[@]}" -gt 0 ]; then
    echo "-- clang-tidy-analyzer: checking ${#TO_RUN_FILES[@]} translation unit(s) (${JOBS} parallel jobs) --"
    running=0
    for i in "${!TO_RUN_FILES[@]}"; do
        run_check "${TO_RUN_FILES[$i]}" "${TO_RUN_DBS[$i]}" "$i" &
        running=$((running + 1))
        if [ "$running" -ge "$JOBS" ]; then
            wait -n || true
            running=$((running - 1))
        fi
    done
    wait || true

    for i in "${!TO_RUN_FILES[@]}"; do
        rel="${TO_RUN_FILES[$i]#"$ROOT_DIR"/}"
        cat "$RESULT_DIR/$i.log"
        if [ "$(cat "$RESULT_DIR/$i.status")" = "0" ]; then
            NEW_CACHE["$rel"]="${TO_RUN_FPS[$i]}"
        else
            STATUS=1
        fi
    done
fi

{
    for unit in "${!NEW_CACHE[@]}"; do
        printf '%s\t%s\n' "$unit" "${NEW_CACHE[$unit]}"
    done
} > "$CACHE_FILE"

echo "check-tidy-analyzer: ${CHECKED_COUNT} checked, ${SKIPPED_COUNT} unchanged since last clean run"

exit $STATUS
