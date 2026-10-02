cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(arm_firmware)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_custom_target(check-format
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/check-format.sh"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Checking clang-format compliance (main/, components/)"
    VERBATIM
)

add_custom_target(check-tidy
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/check-tidy.sh" "${CMAKE_BINARY_DIR}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Running clang-tidy over main/ and components/"
    VERBATIM
)

# Kept separate from check-tidy above: the Clang Static Analyzer
# (clang-analyzer-*) is path-sensitive symbolic execution, an order of
# magnitude more expensive per translation unit than the AST-matcher
# checks in check-tidy. See .clang-tidy-analyzer and
# scripts/check-tidy-analyzer.sh.
add_custom_target(check-tidy-analyzer
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/check-tidy-analyzer.sh" "${CMAKE_BINARY_DIR}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Running the clang-analyzer checks over main/ and components/"
    VERBATIM
)
