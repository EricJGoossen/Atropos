#include <freertos/task.h>

#include <cstdio>

const int kDebugPin = 2;

static const uint16_t timer_divider = 80;
static const uint64_t timer_max_count = 1000;

static hw_timer_t* timer = NULL;

// app_main is the fixed entry-point name ESP-IDF looks for (extern "C",
// so no C++ naming convention applies, but clang-tidy's naming check
// doesn't know that) -- not renameable.
// NOLINTNEXTLINE(readability-identifier-naming)
extern "C" void app_main(void) {}

void IRAM_ATTR onTimer(void* param) {
  BaseType_t xHigherPriorityTaskWoken = pdFalse;
  vTaskNotifyGiveFromISR(ControlTaskHandle, &xHigherPriorityTaskWoken);

  if (xHigherPriorityTaskWoken) {
    portYIELD_FROM_ISR();
  }
}

void ControlTask(void* pvParameters) {
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    digitalWrite(DEBUG_PIN, HIGH);
    digitalWrite(DEBUG_PIN, LOW);
  }
}

void Setup() {
  pinMode(kDebugPin, OUTPUT);
  xTaskCreatePinnedToCore(
      EvaluateControl,
      "Run Controls",
      2048,
      NULL,
      1,
      &ControlTaskHandle,
      app_cpu
  );

  timer = timerBegin(0, timer_divider, true);

  timerAttachInterrupt(timer, &onTimer, true);

  timerAlarmWrite(timer, timer_max_count, true);

  timerAlarmEnable(timer);
}