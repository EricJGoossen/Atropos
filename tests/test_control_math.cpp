// Smoke test for control_math/control_math.hpp -- confirms the host test
// harness builds and links against components/control_math correctly.
// Not meant as the real test suite: add actual coverage alongside the real
// control_math code as it lands.
#include <gtest/gtest.h>

#include "control_math/control_math.hpp"

namespace control_math {
namespace {

TEST(ControlMathSmokeTest, LinksAgainstComponent) {
  EXPECT_EQ(ApiVersion(), 0);
}

}  // namespace
}  // namespace control_math
