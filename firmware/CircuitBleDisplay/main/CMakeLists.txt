idf_component_register(
    SRCS "main.cpp"
    REQUIRES app_update board_display bt driver esp_pm esp_hw_support esp_adc esp_app_format esp_https_server esp_timer esp_wifi fatfs lwip mbedtls nvs_flash sdmmc waveshare__pcf85063a
)

# Development console for testing sync from the Mac: idf.py -DCIRCUIT_DEV_CONSOLE=1 build (see tools/board_dev.py)
if(CIRCUIT_DEV_CONSOLE)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE CIRCUIT_DEV_CONSOLE=1)
endif()

# Sleep from the first second, even with the development console (which otherwise leaves light sleep off, as the
# USB port drops out while the chip sleeps): idf.py -DCIRCUIT_LIGHT_SLEEP=1 build (tools/board_dev.py build --sleep)
if(CIRCUIT_LIGHT_SLEEP)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE CIRCUIT_LIGHT_SLEEP=1)
endif()
