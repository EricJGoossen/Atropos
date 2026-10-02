# Pinned ESP-IDF toolchain image. Bump IDF_VERSION deliberately: behavior
# (scheduler, cache, driver timing) can change between IDF releases, and
# this project has measurable jitter requirements.
# Also update it in .github/workflows/build-ci-image.yml if you ever pass it
# as a build-arg there (currently the default below is the single source).
ARG IDF_VERSION=v5.5.3
FROM espressif/idf:${IDF_VERSION}

# build-essential: not for the firmware itself (that's built by the xtensa
# toolchain IDF already carries) but for tests/, which compiles
# components/control_math/ as a plain native binary so the pure-logic unit
# tests (calibration lookup, tendon health classification, ...) run on the
# host with no board attached -- see tests/CMakeLists.txt and README.md.
# cmake/ninja-build are installed system-wide too (not just IDF's copies,
# which are only on PATH after sourcing export.sh) so CI jobs that never
# source it can still configure tests/; gcovr is for scripts/check-coverage.sh.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ccache \
    clangd-18 \
    cmake \
    gcovr \
    ninja-build \
    gnupg \
    lsb-release \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# clang-format/clang-tidy pinned to an explicit LLVM version (via
# apt.llvm.org) rather than whatever this base image's default apt
# archive resolves them to -- that's what keeps local results matching
# CI's (.github/workflows/ci.yml runs the same image). scripts/check-format.sh
# and scripts/check-tidy*.sh always run whichever version update-alternatives
# points the unversioned name at.
RUN wget https://apt.llvm.org/llvm.sh -O /tmp/llvm.sh \
    && chmod +x /tmp/llvm.sh \
    && /tmp/llvm.sh 18 \
    && apt-get update \
    && apt-get install -y --no-install-recommends clang-format-18 clang-tidy-18 \
    && update-alternatives --install /usr/bin/clang-format clang-format /usr/bin/clang-format-18 100 \
    && update-alternatives --install /usr/bin/clang-tidy clang-tidy /usr/bin/clang-tidy-18 100 \
    && update-alternatives --install /usr/bin/clangd clangd /usr/bin/clangd-18 100 \
    && rm -rf /var/lib/apt/lists/* /tmp/llvm.sh

# VS Code terminals don't go through the image ENTRYPOINT (which is what
# normally activates the IDF environment), so do it for interactive shells.
RUN echo '. $IDF_PATH/export.sh > /dev/null 2>&1' >> ~/.bashrc \
    && echo "alias build='idf.py build'" >> ~/.bashrc

ENV IDF_CCACHE_ENABLE=1
