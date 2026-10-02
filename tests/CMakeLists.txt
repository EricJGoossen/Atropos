cmake_minimum_required(VERSION 3.16)
project(arm_firmware_tests CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(ENABLE_COVERAGE "Instrument control_math with gcov coverage flags" OFF)

include(FetchContent)
FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG v1.15.2
    GIT_SHALLOW TRUE
)
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
set(BUILD_GMOCK OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

# Compiled directly from components/control_math/ rather than vendored --
# this is the same source the firmware build uses, just targeting the host.
set(CONTROL_MATH_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../components/control_math")

add_library(control_math
    "${CONTROL_MATH_DIR}/src/control_math.cpp"
)
target_include_directories(control_math PUBLIC "${CONTROL_MATH_DIR}/include")

if(ENABLE_COVERAGE)
    if(NOT CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
        message(FATAL_ERROR "ENABLE_COVERAGE needs GCC or Clang (got ${CMAKE_CXX_COMPILER_ID})")
    endif()
    # --coverage works the same way (gcov-format .gcno/.gcda output) on
    # both GCC and Clang, so one flag set covers either compiler -- no
    # need to branch on CMAKE_CXX_COMPILER_ID beyond the check above.
    target_compile_options(control_math PUBLIC --coverage -O0 -g)
    target_link_options(control_math PUBLIC --coverage)
endif()

enable_testing()
add_executable(test_control_math
    test_control_math.cpp
)
target_link_libraries(test_control_math PRIVATE control_math GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(test_control_math)
