#!/usr/bin/env python3
"""Internal helper for scripts/check-tidy.sh and check-tidy-analyzer.sh.

Writes a clang-tidy-compatible copy of ESP-IDF's compile_commands.json.
The original is recorded for the xtensa cross gcc, which upstream clang
(e.g. the pinned clang-tidy-18) can't consume as-is:

- it has no xtensa target, so the triple implied by the compiler name
  (xtensa-esp32-elf-g++) is an "unknown target triple" error. Each entry
  is retargeted to riscv32-unknown-elf instead -- another 32-bit
  bare-metal ELF target, close enough for lint purposes;
- a handful of xtensa-gcc-only flags are "unknown argument" errors, so
  they're dropped (the same reason .clangd strips -m*/-f* for clangd);
- clang doesn't know the cross gcc's built-in search paths (libstdc++,
  newlib), so those are queried from the compiler itself and appended as
  -isystem. gcc's own lib/gcc/.../include dirs are skipped: clang ships
  its own builtin headers (stddef.h, stdarg.h, ...) in their place.

The original database is left untouched -- check-tidy.sh's `-M`
dependency scan still runs the real gcc against it.

Usage: _clang_compile_db.py <compile_commands.json> <output-dir>
"""

import json
import os
import shlex
import subprocess
import sys

CLANG_TARGET = "riscv32-unknown-elf"

GCC_ONLY_FLAGS = {
    "-mlongcalls",
    "-fno-shrink-wrap",
    "-fno-tree-switch-conversion",
    "-fstrict-volatile-bitfields",
}


def gcc_system_dirs(compiler: str, lang: str) -> list[str]:
    result = subprocess.run(
        [compiler, f"-x{lang}", "-E", "-v", "-"],
        input="",
        capture_output=True,
        text=True,
        check=False,
    )
    lines = result.stderr.splitlines()
    try:
        start = lines.index("#include <...> search starts here:")
        end = lines.index("End of search list.")
    except ValueError:
        return []
    dirs = [os.path.normpath(line.strip()) for line in lines[start + 1 : end]]
    return [d for d in dirs if "/lib/gcc/" not in d]


def main() -> int:
    db_path, out_dir = sys.argv[1], sys.argv[2]
    with open(db_path, encoding="utf-8") as f:
        entries = json.load(f)

    system_dirs: dict[tuple[str, str], list[str]] = {}
    for entry in entries:
        if "arguments" in entry:
            args = list(entry["arguments"])
        else:
            args = shlex.split(entry.pop("command"))

        compiler = args[0]
        lang = "c" if entry.get("file", "").endswith(".c") else "c++"
        key = (compiler, lang)
        if key not in system_dirs:
            system_dirs[key] = gcc_system_dirs(compiler, lang)

        new_args = [compiler, f"--target={CLANG_TARGET}"]
        new_args += [a for a in args[1:] if a not in GCC_ONLY_FLAGS]
        for d in system_dirs[key]:
            new_args += ["-isystem", d]
        entry["arguments"] = new_args

    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "compile_commands.json"), "w", encoding="utf-8") as f:
        json.dump(entries, f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
