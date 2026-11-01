#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <stdio.h>

#include <cstdio>

#include "driver/gpio.h"
#include "driver/gptimer.h"

#define kDebugPin GPIO_NUM_1

static const uint16_t timer_divider = 80;
static const uint64_t timer_max_count = 1000;

// app_main is the fixed entry-point name ESP-IDF looks for (extern "C",
// so no C++ naming convention applies, but clang-tidy's naming check
// doesn't know that) -- not renameable.
// NOLINTNEXTLINE(readability-identifier-naming)
extern "C" void app_main(void) { Setup(); }

void IRAM_ATTR onTimer(void* param) {
  BaseType_t xHigherPriorityTaskWoken = pdFALSE;
  vTaskNotifyGiveFromISR(ControlTaskHandle, &xHigherPriorityTaskWoken);

  if (xHigherPriorityTaskWoken) {
    return;
  }
}

void ControlTask(void* pvParameters) {
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    gpio_set_level(kDebugPin, 1);
    gpio_set_level(kDebugPin, 0);
  }
}

void g_control_taskhandle() {}

void Setup() {
  gpio_config_t io_conf = {
      .pin_bit_mask = (1ULL << BUTTON_GPIO),
      .mode = GPIO_MODE_OUTPUT,
      .pull_up_en = GPIO_PULLUP_ENABLE,
      .pull_down_en = GPIO_PULLUP_DISABLE,
      .intr_type = GPIO_INTR_DISABLE
  };
  gpio_config(&io_conf);

  gpio_config xTaskCreatePinnedToCore(
      EvaluateControl,
      "Run Controls",
      2048,
      NULL,
      1,
      &g_control_taskhandle,
      portNUM_PROCESSORS - 1
  );

  gptimer_handle_t kMainLoopTimer = NULL;
  gptimer_config_t timer_config = {
      .clk_src = GPTIMER_CLK_SRC_DEFAULT,
      .direction = GPTIMER_COUNT_UP,
      .resolution_hz = 1 * 1000 * 1000,
  };

  gptimer_alarm_config_t main_loop_config = {
      .reload_count = 0,
      .alarm_count = 1000,
      .flags =
          {
              auto_reload_on_alarm = true,
          },
  };

  ESP_ERROR_CHECK(gptimer_new_timer(&timer_config, &kMainLoopTimer));

  ESP_ERROR_CHECK(gptimer_set_alarm_action(kMainLoopTimer, &main_loop_config));

  gptimer_event_callbacks_t cbs = {
      .on_alarm = g_control_taskhandle,
  };

  ESP_ERROR_CHECK(gptimer_register_event_callbacks(gptimer_t timer, &cbs, NULL)
  );

  ESP_ERROR_CHECK(gptimer_enable(kMainLoopTimer));

  ESP_ERROR_CHECK(gptimer_start(kMainLoopTimer));
}