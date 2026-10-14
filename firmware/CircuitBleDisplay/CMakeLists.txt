cmake_minimum_required(VERSION 3.16)

# Reuse Waveshare's checked, board-specific LVGL component set without changing
# the factory-program project.
set(EXTRA_COMPONENT_DIRS
    "${CMAKE_CURRENT_LIST_DIR}/../../vendor/waveshare-board/02_Example/ESP-IDF/V2/11_FactoryProgram/managed_components"
    "${CMAKE_CURRENT_LIST_DIR}/../../vendor/waveshare-board/02_Example/ESP-IDF/V2/11_FactoryProgram/components/externlib/codec_board"
)

# ESP-IDF 5.5.3's Bluetooth library deletes a stored pairing after ANY failed security handshake, even a
# timeout on a weak link, which left the phone and the board disagreeing and the app asking to repair. The
# patch keeps the pairing through failures that are about the link and removes it only when the keys do not
# match. It applies itself here, once, so a build on this Mac and the cloud build both have it, and a build
# that could not get it stops instead of quietly shipping without it. (See idf-patches/.)
set(CIRCUIT_BOND_FILE "$ENV{IDF_PATH}/components/bt/host/bluedroid/btc/core/btc_dm.c")
file(READ "${CIRCUIT_BOND_FILE}" CIRCUIT_BOND_SOURCE)
string(FIND "${CIRCUIT_BOND_SOURCE}" "CIRCUIT_KEEP_BOND_PATCH" CIRCUIT_BOND_PATCHED)
if(CIRCUIT_BOND_PATCHED EQUAL -1)
  execute_process(
    COMMAND git apply --whitespace=nowarn "${CMAKE_CURRENT_LIST_DIR}/idf-patches/keep-bond-on-transient-failure.patch"
    WORKING_DIRECTORY "$ENV{IDF_PATH}"
    RESULT_VARIABLE CIRCUIT_PATCH_RESULT
    ERROR_VARIABLE CIRCUIT_PATCH_ERROR)
  if(NOT CIRCUIT_PATCH_RESULT EQUAL 0)
    message(FATAL_ERROR "Could not apply idf-patches/keep-bond-on-transient-failure.patch to ESP-IDF "
                        "($ENV{IDF_PATH}): ${CIRCUIT_PATCH_ERROR}")
  endif()
  message(STATUS "Applied idf-patches/keep-bond-on-transient-failure.patch to ESP-IDF")
endif()

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# Shown in the boot log and, later, to the app. Bump it for each firmware release.
set(PROJECT_VER "2.0.0-dev1")
project(circuit_ble_display)
