set(WAVESHARE_BSP
    "${CMAKE_CURRENT_LIST_DIR}/../../../../vendor/waveshare-board/02_Example/ESP-IDF/V2/11_FactoryProgram/components/port_bsp")

idf_component_register(
    SRCS
        "${WAVESHARE_BSP}/port_power.cpp"
        "${WAVESHARE_BSP}/port_display.cpp"
        "${WAVESHARE_BSP}/port_lvgl.cpp"
    INCLUDE_DIRS
        "${WAVESHARE_BSP}"
    REQUIRES
        driver
        esp_timer
        lvgl
)
