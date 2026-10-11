#pragma once

// A copy of the board's log on the SD card, so what happened is still there when no computer
// was listening (for example while the phone and the board were apart).
//
//   /sdcard/LOGS/CIRCUIT0.LOG   the current file
//   /sdcard/LOGS/CIRCUIT1.LOG   the one before it, then CIRCUIT2.LOG and CIRCUIT3.LOG, the oldest
//
// Each line starts with the time the board's clock says (UTC; "--" until the phone has set it),
// then the line as it went to the serial port. Four files of up to 2 MB are the most it ever
// holds (days of normal use), and it stops writing when the card is nearly full, so it can never
// crowd out notes. Lines are written in the background, a couple of
// seconds after they are logged, from a buffer in PSRAM: logging never waits for the card, and a
// line is dropped rather than slowing anything down if the buffer is full.
// The log holds no recordings or keys, but it does hold device addresses: it stays on the card.

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <sys/stat.h>
#include <unistd.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/idf_additions.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

namespace circuit_sdlog {

constexpr size_t kRingBytes = 24 * 1024;        // PSRAM
constexpr size_t kMaxFileBytes = 2 * 1024 * 1024;
constexpr int kFiles = 4;
constexpr size_t kLineBytes = 220;               // longer lines are cut
constexpr uint32_t kWriteEveryMs = 2000;

inline char *ring = nullptr;
inline volatile size_t head = 0;                 // next byte to write into
inline volatile size_t tail = 0;                 // next byte to write to the card
inline volatile uint32_t dropped = 0;
inline portMUX_TYPE lock = portMUX_INITIALIZER_UNLOCKED;
// One shared buffer for formatting, so a task that logs pays almost nothing on its own stack
// (some of the board's tasks have little to spare). A line that finds it busy is skipped.
inline char shared_line[kLineBytes];
inline SemaphoreHandle_t format_lock = nullptr;
inline vprintf_like_t previous = nullptr;
inline volatile bool card_ready = false;
// Set by the firmware: false when the card is too full to spend room on the log.
inline bool (*room_ok)() = nullptr;

inline size_t used_bytes() { return (head + kRingBytes - tail) % kRingBytes; }

inline int hook(const char *format, va_list args) {
    va_list copy;
    va_copy(copy, args);
    const int written = previous != nullptr ? previous(format, args) : vprintf(format, args);
    if (ring != nullptr && format_lock != nullptr && !xPortInIsrContext() && xSemaphoreTake(format_lock, 0) == pdTRUE) {
        char *line = shared_line;
        size_t length = 0;
        const time_t now = time(nullptr);
        if (now > 1704067200) {  // the clock has been set
            struct tm parts;
            gmtime_r(&now, &parts);
            length = strftime(line, kLineBytes, "%m-%d %H:%M:%S ", &parts);
        } else {
            length = static_cast<size_t>(snprintf(line, kLineBytes, "-- "));
        }
        const int body = vsnprintf(line + length, kLineBytes - length, format, copy);
        if (body > 0) {
            length += static_cast<size_t>(body);
            if (length > kLineBytes - 1) length = kLineBytes - 1;  // a long line is cut
        }
        // IDF lines end in a newline already; make sure a cut one does too.
        if (length == 0 || line[length - 1] != '\n') {
            if (length > kLineBytes - 1) length = kLineBytes - 1;
            line[length] = '\n';
            length += 1;
        }
        portENTER_CRITICAL_SAFE(&lock);
        if (kRingBytes - 1 - used_bytes() >= length) {
            for (size_t i = 0; i < length; ++i) {
                ring[head] = line[i];
                head = (head + 1) % kRingBytes;
            }
        } else {
            dropped = dropped + 1;
        }
        portEXIT_CRITICAL_SAFE(&lock);
        xSemaphoreGive(format_lock);
    }
    va_end(copy);
    return written;
}

// Start copying log lines into the buffer. Safe to call before the card is there.
inline void install() {
    if (ring != nullptr) return;
    ring = static_cast<char *>(heap_caps_malloc(kRingBytes, MALLOC_CAP_SPIRAM));
    if (ring == nullptr) return;
    format_lock = xSemaphoreCreateMutex();
    if (format_lock == nullptr) return;
    previous = esp_log_set_vprintf(hook);
}

inline void write_task(void *) {
    const char *directory = "/sdcard/LOGS";
    const char *current = "/sdcard/LOGS/CIRCUIT0.LOG";
    mkdir(directory, 0777);
    FILE *file = fopen(current, "ab");
    size_t file_bytes = 0;
    if (file != nullptr) {
        fseek(file, 0, SEEK_END);
        file_bytes = static_cast<size_t>(ftell(file));
        fprintf(file, "---- log opened (card ready) ----\n");
    }
    char chunk[512];
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(kWriteEveryMs));
        if (file == nullptr) {
            file = fopen(current, "ab");
            if (file == nullptr) continue;
        }
        bool wrote = false;
        if (room_ok != nullptr && !room_ok()) {
            // The card is nearly full: recordings come first. Forget what is waiting.
            portENTER_CRITICAL(&lock);
            tail = head;
            portEXIT_CRITICAL(&lock);
            continue;
        }
        while (used_bytes() > 0) {
            size_t count = 0;
            portENTER_CRITICAL(&lock);
            while (tail != head && count < sizeof(chunk)) {
                chunk[count++] = ring[tail];
                tail = (tail + 1) % kRingBytes;
            }
            portEXIT_CRITICAL(&lock);
            if (fwrite(chunk, 1, count, file) != count) break;
            file_bytes += count;
            wrote = true;
            if (file_bytes >= kMaxFileBytes) {
                fclose(file);
                char from[40], to[40];
                snprintf(to, sizeof(to), "/sdcard/LOGS/CIRCUIT%d.LOG", kFiles - 1);
                remove(to);
                for (int i = kFiles - 2; i >= 0; --i) {
                    snprintf(from, sizeof(from), "/sdcard/LOGS/CIRCUIT%d.LOG", i);
                    snprintf(to, sizeof(to), "/sdcard/LOGS/CIRCUIT%d.LOG", i + 1);
                    rename(from, to);
                }
                file = fopen(current, "ab");
                file_bytes = 0;
                if (file == nullptr) break;
            }
        }
        if (dropped > 0 && file != nullptr) {
            fprintf(file, "---- %u log line(s) dropped: the buffer was full ----\n", static_cast<unsigned>(dropped));
            dropped = 0;
            wrote = true;
        }
        if (wrote && file != nullptr) {
            fflush(file);
            fsync(fileno(file));  // a power cut loses at most the last couple of seconds
        }
    }
}

// Call once the card is mounted. The stack is in PSRAM: nothing here touches the board's flash.
inline void start_writer() {
    if (ring == nullptr || card_ready) return;
    card_ready = true;
    xTaskCreatePinnedToCoreWithCaps(write_task, "sd_log", 4096, nullptr, 1, nullptr, tskNO_AFFINITY,
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
}

}  // namespace circuit_sdlog
