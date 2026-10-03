idf_component_register(
    SRCS "main.cpp"
    REQUIRES board_display bt esp_wifi fatfs lwip nvs_flash sdmmc
)
