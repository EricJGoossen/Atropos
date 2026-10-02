#!/usr/bin/env python3
"""Internal helper for scripts/check-tidy.sh and check-tidy-analyzer.sh.

Looks up one file's entry in a compile_commands.json and prints its build
directory followed by its argv (compiler included), NUL-separated, so the
calling script can run that file's *own* compiler with its *own* flags for
a `-M` dependency scan -- this is what lets dependency fingerprinting work
for any TU (ESP-IDF's xtensa cross g++ for firmware files, the host g++/
clang++ for tests/*.cpp) without hardcoding each one's include paths by
hand, the way a small, fixed FetchContent dependency list could.

Usage: _compile_flags_for.py <compile_commands.json> <absolute-file-path>
Exits 1 (no output) if the file has no entry in that database.
"""

import json
import os
import shlex
import sys


def main() -> int:
    db_path, target = sys.argv[1], sys.argv[2]
    with open(db_path, encoding="utf-8") as f:
        entries = json.load(f)

    norm_target = os.path.normpath(target)
    match = None
    for entry in entries:
        file_field = entry.get("file", "")
        directory = entry.get("directory", "")
        candidate = (
            file_field
            if os.path.isabs(file_field)
            else os.path.normpath(os.path.join(directory, file_field))
        )
        if os.path.normpath(candidate) == norm_target:
            match = entry
            break

    if match is None:
        return 1

    if "arguments" in match:
        args = list(match["arguments"])
    else:
        args = shlex.split(match["command"])

    sys.stdout.write(match.get("directory", "") + "\0")
    for arg in args:
        sys.stdout.write(arg + "\0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
