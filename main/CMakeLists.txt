idf_component_register(
    SRCS
        "main.cpp"
        "GetMotorPWM.cpp"

    INCLUDE_DIRS
        "."

    REQUIRES
        control_math
        esp_driver_gpio
        esp_driver_gptimer
        esp_driver_mcpwm
)