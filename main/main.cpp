#include <cstdio>

// app_main is the fixed entry-point name ESP-IDF looks for (extern "C",
// so no C++ naming convention applies, but clang-tidy's naming check
// doesn't know that) -- not renameable.
// NOLINTNEXTLINE(readability-identifier-naming)
extern "C" void app_main(void) {}
