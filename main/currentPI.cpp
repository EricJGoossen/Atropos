#include "currentPI.h"

int32_t PI_LOOP : pi_update(int32_t intended, int32_t actual) {
  int32_t error = (intended - actual);
  accumulated += error;
  int32_t iMod = (accumulated * kI);
  int32_t pMod = (error * kP);
  return iMod + pMod;
}

void PI_LOOP : pi_reset() { accumulated = 0; }
