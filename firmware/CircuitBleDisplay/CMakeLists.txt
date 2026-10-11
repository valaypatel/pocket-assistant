cmake_minimum_required(VERSION 3.16)

# Reuse Waveshare's checked, board-specific LVGL component set without changing
# the factory-program project.
set(EXTRA_COMPONENT_DIRS
    "${CMAKE_CURRENT_LIST_DIR}/../../vendor/waveshare-board/02_Example/ESP-IDF/V2/11_FactoryProgram/managed_components"
    "${CMAKE_CURRENT_LIST_DIR}/../../vendor/waveshare-board/02_Example/ESP-IDF/V2/11_FactoryProgram/components/externlib/codec_board"
)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# Shown in the boot log and, later, to the app. Bump it for each firmware release.
set(PROJECT_VER "2.0.0-dev1")
project(circuit_ble_display)
