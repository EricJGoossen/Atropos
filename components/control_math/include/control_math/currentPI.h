#pragma once
#define init_kP 1
#define init_kI 100

class PI_LOOP {
 private:
  int32_t accumulated;
  const int32_t kP;
  const int32_t kI;

 public:
  void pi_init() {
    accumulated = 0;
    kP = init_kP;
    kI = init_kI;
  }
  int32_t pi_update(int32_t intended, int32_t actual);
  void pi_reset();
}