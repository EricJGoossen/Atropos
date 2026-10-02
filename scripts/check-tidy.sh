#!/usr/bin/env bash
# Fails if clang-tidy reports any warning under main/, components/, or tests/.
#
# This only lints the real main/*.cpp, components/*/src/*.cpp, and
# tests/*.cpp translation units (via compile databases) -- it does NOT
# compile each header standalone. That relies on an invariant this script
# also enforces: every header under components/*/include/ must be
# reachable (via #include, transitively) from at least one
# main/*.cpp or components/*/src/*.cpp file, so clang-tidy's
# --header-filter actually reaches it from a real TU. If a header falls
# out of its reachable set (e.g. a new header nothing includes yet), this
# script fails loudly on the "orphaned header" check below rather than
# silently skipping it.
#
# Two separate compile databases, not one: main/*.cpp and
# components/*/src/*.cpp are built by idf.py (the xtensa cross toolchain,
# $BUILD_DIR/compile_commands.json); tests/*.cpp is a plain host binary
# built by its own CMake project under tests/ ($TESTS_BUILD_DIR/
# compile_commands.json) -- see tests/CMakeLists.txt and README.md for why
# that's a separate build rather than folded into the firmware one. Each
# file is linted with `-p` pointed at whichever database actually compiled
# it.
#
# A tests/*.cpp file picks up tests/.clang-tidy (its nearest config, found
# by walking up from the file) instead of the root .clang-tidy -- that's
# plain clang-tidy config resolution, not something this script arranges.
#
# Checking every file on every run is slow, so a persistent cache in
# $BUILD_DIR skips re-running clang-tidy on a .cpp file whose relevant
# content hasn't changed since it last passed clean. "Relevant content" is
# the file itself plus every project header it transitively includes (via
# that file's own compiler, with its own flags from its compile database --
# see scripts/_compile_flags_for.py) plus the two .clang-tidy configs and
# this script, so the cache invalidates itself whenever anything that
# could change the check's outcome changes -- not just the file itself. A
# file is cached ONLY when it passes: a file that's currently failing is
# always re-run and re-reported, every time, until it's actually fixed --
# never silently skipped just because nobody happened to touch it in this
# particular session.
#
# Usage: scripts/check-tidy.sh [firmware-build-dir] [tests-build-dir]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-$ROOT_DIR/build}"
TESTS_BUILD_DIR="${2:-$ROOT_DIR/build-tests}"
COMPILE_DB="$BUILD_DIR/compile_commands.json"
TESTS_COMPILE_DB="$TESTS_BUILD_DIR/compile_commands.json"
CACHE_FILE="$BUILD_DIR/.check-tidy-cache"
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

# The tests/ build is optional here (someone may be running a quick
# firmware-only check-tidy before ever configuring tests/) -- skip tests/
# linting with a warning rather than hard-failing the whole script, unlike
# the firmware compile DB above which this check genuinely can't proceed
# without.
RUN_TESTS=1
if [ ! -f "$TESTS_COMPILE_DB" ]; then
    echo "warning: $TESTS_COMPILE_DB not found -- skipping tests/ (run" \
         "'cmake -S tests -B $TESTS_BUILD_DIR' first to include it)." >&2
    RUN_TESTS=0
fi

SRC_HEADER_FILTER="^${ROOT_DIR}/(main|components)/.*"
TEST_HEADER_FILTER="^${ROOT_DIR}/tests/.*"

# Hashes both .clang-tidy configs (root and tests/ -- a tests/*.cpp file
# resolves tests/.clang-tidy as its nearest config, not the root one) and
# this script (and its flags helper), so a config or flag change
# invalidates every cache entry at once, the same as a source edit would.
CONFIG_HASH="$(cat "$ROOT_DIR/.clang-tidy" "$ROOT_DIR/tests/.clang-tidy" "$FLAGS_HELPER" "$CLANG_DB_HELPER" "${BASH_SOURCE[0]}" | sha256sum | awk '{print $1}')"

# Prints one project header/source path per line that $1 (compiled by
# database $2) transitively includes, restricted to files under main/,
# components/, or tests/ -- third-party headers (googletest, the ESP-IDF
# SDK itself) are deliberately excluded: they're pinned by CMakeLists.txt/
# the IDF version, not edited here, and hashing them on every run would be
# pure overhead. Runs the file's own compiler with its own recorded flags
# (via $FLAGS_HELPER) rather than a hardcoded compiler/include list, since
# main/*.cpp and tests/*.cpp are compiled by two different toolchains.
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

# A file's fingerprint is the config hash plus the content hash of every
# file project_deps_of finds -- so it changes if the file itself changes,
# if any header it includes changes, or if a .clang-tidy config/this
# script/its flags helper change.
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

# clang-tidy invocations are independent per translation unit and dominate
# the runtime, so they run concurrently (bounded by JOBS) instead of one at
# a time. Fingerprinting stays sequential -- it's just a `-M` scan plus
# hashing, not a full clang-tidy run, so it's cheap relative to the
# analysis itself and doesn't need parallelizing.
JOBS="${CHECK_TIDY_JOBS:-$(nproc 2>/dev/null || echo 4)}"
# A fresh, unique directory per invocation (not a fixed name under
# $BUILD_DIR) -- two check-tidy.sh runs against the same build dir (e.g.
# a local run overlapping with CI, or just two terminals) would otherwise
# race on the same result files, each clobbering the other's in-flight
# output.
RESULT_DIR="$(mktemp -d "$BUILD_DIR/.check-tidy-parallel.XXXXXX")"
trap 'rm -rf "$RESULT_DIR"' EXIT

# clang-tidy can't read the firmware compile database as-is (it's recorded
# for the xtensa cross gcc) -- lint firmware TUs against a clang-compatible
# copy instead; see $CLANG_DB_HELPER. Fingerprinting keeps using the
# original, since its `-M` scan runs the real gcc.
FIRMWARE_TIDY_DB="$RESULT_DIR/firmware-db"
python3 "$CLANG_DB_HELPER" "$COMPILE_DB" "$FIRMWARE_TIDY_DB"

# Non-recursive: main/ and tests/ are flat by design (see README.md), and
# a components/*/src/ is one level under its own component -- a nested
# src/ dir deeper than that would be a layering question worth noticing,
# not silently picking up.
mapfile -t MAIN_FILES < <(find "$ROOT_DIR/main" -maxdepth 1 -name '*.cpp' | sort)
mapfile -t COMPONENT_FILES < <(find "$ROOT_DIR/components" -mindepth 2 -maxdepth 2 -path '*/src' -type d \
    -exec find {} -maxdepth 1 -name '*.cpp' \; 2>/dev/null | sort)
SRC_FILES=("${MAIN_FILES[@]}" "${COMPONENT_FILES[@]}")

TEST_FILES=()
if [ "$RUN_TESTS" = "1" ]; then
    mapfile -t TEST_FILES < <(find "$ROOT_DIR/tests" -maxdepth 1 -name '*.cpp' | sort)
fi

ALL_UNITS=() ALL_FILTERS=() ALL_DBS=()
for src in "${SRC_FILES[@]}"; do
    ALL_UNITS+=("$src"); ALL_FILTERS+=("$SRC_HEADER_FILTER"); ALL_DBS+=("$BUILD_DIR")
done
for test_src in "${TEST_FILES[@]}"; do
    ALL_UNITS+=("$test_src"); ALL_FILTERS+=("$TEST_HEADER_FILTER"); ALL_DBS+=("$TESTS_BUILD_DIR")
done

# Phase 1: resolve which units are already cached as passing (cheap -- no
# clang-tidy invocation involved) versus which actually need to be checked.
TO_RUN_FILES=() TO_RUN_FILTERS=() TO_RUN_DBS=() TO_RUN_FPS=()
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
    TO_RUN_FILTERS+=("${ALL_FILTERS[$i]}")
    if [ "${ALL_DBS[$i]}" = "$BUILD_DIR" ]; then
        TO_RUN_DBS+=("$FIRMWARE_TIDY_DB")
    else
        TO_RUN_DBS+=("${ALL_DBS[$i]}")
    fi
    TO_RUN_FPS+=("$fp")
done
CHECKED_COUNT="${#TO_RUN_FILES[@]}"

# Phase 2: run the actual clang-tidy invocations, up to JOBS concurrently.
# Each writes its output/exit status to its own file (indexed by position
# in TO_RUN_FILES) instead of the terminal, so results are printed back out
# in a fixed order below -- grouped by file, not interleaved by whichever
# job happens to finish first.
run_check() {
    local file="$1" header_filter="$2" build_dir="$3" idx="$4"
    local rc=0
    # `set -e` (inherited from the parent script) would otherwise kill this
    # background subshell the instant clang-tidy exits non-zero, skipping
    # the status write below and silently losing the result for that file.
    clang-tidy -p "$build_dir" --quiet \
        --header-filter="$header_filter" \
        --warnings-as-errors='*' \
        "$file" > "$RESULT_DIR/$idx.log" 2>&1 || rc=$?
    echo "$rc" > "$RESULT_DIR/$idx.status"
}

if [ "${#TO_RUN_FILES[@]}" -gt 0 ]; then
    echo "-- clang-tidy: checking ${#TO_RUN_FILES[@]} translation unit(s) (${JOBS} parallel jobs) --"
    running=0
    for i in "${!TO_RUN_FILES[@]}"; do
        run_check "${TO_RUN_FILES[$i]}" "${TO_RUN_FILTERS[$i]}" "${TO_RUN_DBS[$i]}" "$i" &
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

echo "check-tidy: ${CHECKED_COUNT} checked, ${SKIPPED_COUNT} unchanged since last clean run"

# Enforce the invariant this whole approach depends on: every header must
# be reachable from some main/*.cpp or components/*/src/*.cpp, or
# clang-tidy never actually sees it. Each component's include/ root is
# walked separately (control_math/calibration.hpp is the #include path,
# relative to components/control_math/include/, not to components/ itself).
for inc_dir in "$ROOT_DIR"/components/*/include; do
    [ -d "$inc_dir" ] || continue
    mapfile -t COMPONENT_HEADERS < <(find "$inc_dir" -name '*.hpp' | sed "s#^${inc_dir}/##" | sort -u)
    [ "${#COMPONENT_HEADERS[@]}" -eq 0 ] && continue

    mapfile -t REACHABLE < <(
        for src in "${SRC_FILES[@]}"; do
            project_deps_of "$src" "$BUILD_DIR/compile_commands.json"
        done | grep -E "^${inc_dir}/" | sed "s#^${inc_dir}/##" | sort -u
    )
    mapfile -t ORPHANED < <(comm -23 <(printf '%s\n' "${COMPONENT_HEADERS[@]}") <(printf '%s\n' "${REACHABLE[@]}"))
    if [ "${#ORPHANED[@]}" -gt 0 ]; then
        comp_name="$(basename "$(dirname "$inc_dir")")"
        echo "check-tidy: the following header(s) in components/$comp_name/include/ aren't" >&2
        echo "reachable from any main/*.cpp or components/*/src/*.cpp file, so clang-tidy" >&2
        echo "never actually checks them -- #include them (directly or transitively) from" >&2
        echo "a real .cpp, or this check can't see them:" >&2
        printf '  components/%s/include/%s\n' "$comp_name" "${ORPHANED[@]}" >&2
        STATUS=1
    fi
done

exit $STATUS
