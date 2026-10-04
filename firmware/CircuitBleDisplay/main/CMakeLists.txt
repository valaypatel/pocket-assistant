idf_component_register(
    SRCS "main.cpp"
    REQUIRES board_display bt driver esp_https_server esp_timer esp_wifi fatfs lwip mbedtls nvs_flash sdmmc
)
