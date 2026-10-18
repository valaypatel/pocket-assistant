// The board's LVGL loop, written for sleeping.
//
// Waveshare's example ticks LVGL from a 5 ms timer and runs its timer handler at least every 50 ms, which keeps
// the processor awake 200 times a second even when nothing on the screen moves. This one reads the clock when
// LVGL asks for it (lv_tick_set_cb), and the LVGL task sleeps until LVGL says its next job is due. Any other
// task that changes the screen under the lock wakes it when it lets go of the lock, so a change still reaches
// the e-paper at once.
//
// The API is the one main.cpp has always used (port_lvgl.h): Lvgl_PortInit, Lvgl_lock, Lvgl_unlock.
#include <stdio.h>
#include <string.h>

#include <esp_heap_caps.h>
#include <esp_log.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include "epaper_config.h"
#include "port_lvgl.h"

static const char *TAG = "circuit_lvgl";

static SemaphoreHandle_t lvgl_mux = nullptr;
static TaskHandle_t lvgl_task = nullptr;
constexpr uint32_t kLongestSleepMs = 1000;  // a safety net, not a rhythm: LVGL's own timers set the pace
constexpr uint32_t kShortestSleepMs = 5;    // never spin

// The lock is recursive: a task that holds it can call code that takes it again (a screen change made of several
// steps holds it through all of them, so only the finished screen is ever drawn, not the steps in between).
bool Lvgl_lock(int timeout_ms) {
    const TickType_t ticks = (timeout_ms == -1) ? portMAX_DELAY : pdMS_TO_TICKS(timeout_ms);
    return xSemaphoreTakeRecursive(lvgl_mux, ticks) == pdTRUE;
}

void Lvgl_unlock(void) {
    assert(lvgl_mux && "Lvgl_PortInit must be called first");
    xSemaphoreGiveRecursive(lvgl_mux);
    // Whoever changed the screen under the lock has probably left something to draw: wake the LVGL task, which
    // may be asleep for up to a second. (Its own unlock must not wake itself, or it would never sleep.)
    if (lvgl_task != nullptr && xTaskGetCurrentTaskHandle() != lvgl_task) xTaskNotifyGive(lvgl_task);
}

static uint32_t tick_ms() { return static_cast<uint32_t>(esp_timer_get_time() / 1000); }

static void lvgl_port_task(void *) {
    for (;;) {
        uint32_t wait_ms = kLongestSleepMs;
        if (Lvgl_lock(-1)) {
            wait_ms = lv_timer_handler();
            Lvgl_unlock();
        }
        if (wait_ms > kLongestSleepMs) wait_ms = kLongestSleepMs;
        if (wait_ms < kShortestSleepMs) wait_ms = kShortestSleepMs;
        // Sleeps until LVGL's next job is due, or until another task has changed the screen.
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(wait_ms));
    }
}

void Lvgl_PortInit(DispFlushCb flush_cb) {
    lvgl_mux = xSemaphoreCreateRecursiveMutex();
    lv_init();
    lv_tick_set_cb(tick_ms);
    lv_display_t *display = lv_display_create(EPD_WIDTH, EPD_HEIGHT);
    lv_display_set_flush_cb(display, flush_cb);

    const size_t buffer_size = EPD_WIDTH * EPD_HEIGHT * LV_COLOR_FORMAT_GET_SIZE(LV_COLOR_FORMAT_RGB565);
    uint8_t *buffer_1 = static_cast<uint8_t *>(heap_caps_malloc(buffer_size, MALLOC_CAP_SPIRAM));
    uint8_t *buffer_2 = static_cast<uint8_t *>(heap_caps_malloc(buffer_size, MALLOC_CAP_SPIRAM));
    assert(buffer_1 && buffer_2);
    lv_display_set_buffers(display, buffer_1, buffer_2, buffer_size, LV_DISPLAY_RENDER_MODE_FULL);

    ESP_LOGI(TAG, "LVGL started (ticked on demand, sleeps between jobs)");
    xTaskCreatePinnedToCore(lvgl_port_task, "LVGL", 8 * 1024, nullptr, 5, &lvgl_task, 0);
}
