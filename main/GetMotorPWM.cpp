/* #include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <stdio.h>

#include <cstdio>

#include "driver/mcpwm_cmpr.h"
#include "driver/mcpwm_prelude.h"
#include "driver/mcpwm_types.h"
#include "esp_err.h"

#define kMotorPin = 1ULL;
#define kISPin = 1ULL;

void setup_motor() {
  mcpwm_timer_handle_t timer = NULL;
  mcpwm_oper_handle_t oper = NULL;
  mcpwm_cmpr_handle_t comparator = NULL;
  mcpwm_gen_handle_t generator = NULL;

  mcpwm_timer_config_t timer_config = (
      &(mcpwm_timer_config_t){
          .group_id = 0,
          .clk_src = MCPWM_TIMER_CLK_SRC_DEFAULT,
          .resolution_hz = 1000000,
          .period_ticks = 2000,
          .count_mode = MCPWM_TIMER_COUNT_MODE_UP,
      },
      &timer
  )
  ESP_ERROR_CHECK();
  ESP_ERROR_CHECK(mcpwm_new_operator(
      &(mcpwm_operator_config_t){
          .group_id = 0,
      },
      &oper
  ));
  ESP_ERROR_CHECK(mcpwm_new_comparator(
      oper,
      &(mcpwm_comparator_config_t){
          .flags.update_cmp_on_tez = true,
      },
      &comparator
  ));
  ESP_ERROR_CHECK(mcpwm_comparator_set_compare_value(compare, 15));

  ESP_ERROR_CHECK(mcpwm_new_generator(
      oper,
      &(mcpwm_generator_config_t){
          .gen_gpio_num = 18,
      },
      &generator
  ));

  ESP_ERROR_CHECK(mcpwm_generator_set_action_on_timer_event(
      generator,
      MCPWM_GEN_TIMER_EVENT_ACTION(
          MCPWM_TIMER_DIRECTION_UP,
          MCPWM_TIMER_EVENT_EMPTY,
          MCPWM_GEN_ACTION_HIGH
      )
  ));
  ESP_ERROR_CHECK(mcpwm_generator_set_action_on_compare_event(
      generator,
      MCPWM_GEN_COMPARE_EVENT_ACTION(
          MCPWM_TIMER_DIRECTION_UP, comparator, MCPWM_GEN_ACTION_LOW
      )
  ));
  ESP_ERROR_CHECK(mcpwm_timer_enable(timer));
  ESP_ERROR_CHECK(mcpwm_timer_start_stop(timer, MCPWM_TIMER_START_NO_STOP));

  ESP_ERROR_CHECK(mcpwm_comparator_set_compare_value(comparator, 25));
} */