set(WAVESHARE_BSP
    "${CMAKE_CURRENT_LIST_DIR}/../../../../vendor/waveshare-board/02_Example/ESP-IDF/V2/11_FactoryProgram/components/port_bsp")

idf_component_register(
    SRCS
        "${WAVESHARE_BSP}/port_power.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/port_display.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/circuit_lvgl.cpp"
        "${WAVESHARE_BSP}/port_codec.cpp"
    INCLUDE_DIRS
        "${WAVESHARE_BSP}"
    REQUIRES
        driver
        esp_timer
        codec_board
        espressif__esp_codec_dev
        lvgl
)
