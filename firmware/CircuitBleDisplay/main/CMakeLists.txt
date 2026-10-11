idf_component_register(
    SRCS "main.cpp"
    REQUIRES board_display bt driver esp_app_format esp_https_server esp_timer esp_wifi fatfs lwip mbedtls nvs_flash sdmmc
)

# Development console for testing sync from the Mac: idf.py -DCIRCUIT_DEV_CONSOLE=1 build (see tools/board_dev.py)
if(CIRCUIT_DEV_CONSOLE)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE CIRCUIT_DEV_CONSOLE=1)
endif()
