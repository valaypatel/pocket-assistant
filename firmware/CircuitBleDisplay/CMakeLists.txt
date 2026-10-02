cmake_minimum_required(VERSION 3.16)

# Reuse Waveshare's checked, board-specific LVGL component set without changing
# the factory-program project.
set(EXTRA_COMPONENT_DIRS
    "${CMAKE_CURRENT_LIST_DIR}/../../vendor/waveshare-board/02_Example/ESP-IDF/V2/11_FactoryProgram/managed_components"
)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(circuit_ble_display)
