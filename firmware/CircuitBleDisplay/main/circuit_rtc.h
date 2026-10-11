#pragma once
// The board's real-time clock chip (PCF85063A, I2C address 0x51, on the codec's I2C bus). It keeps the
// time while the ESP32 is off, so notes recorded right after a power-up carry the right time even
// before the phone or Wi-Fi has set the clock. The chip always holds UTC; the time zone is applied
// by the firmware as before.

#include <cstdint>
#include <ctime>

#include "driver/i2c_master.h"
#include "esp_log.h"

extern "C" {
#include "pcf85063a.h"
}

namespace circuit_rtc {

inline pcf85063a_dev_t device = {};
inline bool ready = false;

// Days from 1970-01-01 to a civil date (proleptic Gregorian). Avoids mktime, which depends on TZ.
inline int64_t days_from_civil(int64_t y, unsigned m, unsigned d) {
    y -= m <= 2;
    const int64_t era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = static_cast<unsigned>(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + static_cast<int64_t>(doe) - 719468;
}

// Call after the codec has started: it owns the I2C bus (port 0, SDA 47, SCL 48).
inline bool init() {
    i2c_master_bus_handle_t bus = nullptr;
    if (i2c_master_get_bus_handle(I2C_NUM_0, &bus) != ESP_OK || bus == nullptr) {
        ESP_LOGW("CircuitRtc", "I2C bus not available; no RTC");
        return false;
    }
    ready = pcf85063a_init(&device, bus, PCF85063A_ADDRESS) == ESP_OK;
    if (!ready) ESP_LOGW("CircuitRtc", "RTC chip did not answer");
    return ready;
}

// Reads the chip as UTC seconds. False when it is missing or does not hold a believable time (after a
// total power loss the chip restarts near 1970/2000).
inline bool read(time_t *utc, time_t min_valid) {
    pcf85063a_datetime_t t = {};
    if (!ready || pcf85063a_get_time_date(&device, &t) != ESP_OK) return false;
    if (t.month < 1 || t.month > 12 || t.day < 1 || t.day > 31 || t.hour > 23 || t.min > 59 || t.sec > 59) return false;
    const int64_t days = days_from_civil(t.year, t.month, t.day);
    const time_t value = static_cast<time_t>(days * 86400 + t.hour * 3600 + t.min * 60 + t.sec);
    if (value < min_valid) return false;
    *utc = value;
    return true;
}

inline bool write(time_t utc) {
    if (!ready) return false;
    tm parts = {};
    gmtime_r(&utc, &parts);
    pcf85063a_datetime_t t = {};
    t.year = static_cast<uint16_t>(parts.tm_year + 1900);
    t.month = static_cast<uint8_t>(parts.tm_mon + 1);
    t.day = static_cast<uint8_t>(parts.tm_mday);
    t.dotw = static_cast<uint8_t>(parts.tm_wday);
    t.hour = static_cast<uint8_t>(parts.tm_hour);
    t.min = static_cast<uint8_t>(parts.tm_min);
    t.sec = static_cast<uint8_t>(parts.tm_sec);
    return pcf85063a_set_time_date(&device, t) == ESP_OK;
}

}  // namespace circuit_rtc
