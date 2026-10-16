#pragma once
// The battery, read from the board's own sense line: GPIO4 (ADC1 channel 3) sits behind a 2:1 divider, so
// the pin sees half the cell voltage (Waveshare's ADC example reads it the same way). Reads are averaged
// and use the chip's factory calibration. Nothing here is fatal: if the ADC cannot start, the battery is
// simply reported as unknown (-1).

#include <cstddef>

#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_log.h"

namespace circuit_battery {

constexpr adc_channel_t kChannel = ADC_CHANNEL_3;  // GPIO4 on the ESP32-S3
constexpr int kDivider = 2;                         // the pin sees half of the battery voltage
constexpr int kSamples = 16;

namespace detail {
inline adc_oneshot_unit_handle_t unit = nullptr;
inline adc_cali_handle_t cali = nullptr;
}  // namespace detail

/// Charge left in a single lithium-polymer cell, 0 to 100, from its resting voltage in millivolts. The curve
/// is the usual rough one (a cell spends most of its life between 3.7 and 4.0 V); it is a guide, not a gauge:
/// voltage sags under load and rises while charging.
inline int percent_from_mv(int mv) {
    struct Point { int mv; int percent; };
    static constexpr Point curve[] = {
        {3300, 0}, {3500, 5}, {3600, 15}, {3700, 35}, {3800, 55},
        {3900, 70}, {4000, 83}, {4100, 94}, {4200, 100},
    };
    if (mv <= curve[0].mv) return 0;
    for (size_t i = 1; i < sizeof(curve) / sizeof(curve[0]); i++) {
        if (mv <= curve[i].mv) {
            const Point& a = curve[i - 1];
            const Point& b = curve[i];
            return a.percent + (b.percent - a.percent) * (mv - a.mv) / (b.mv - a.mv);
        }
    }
    return 100;
}

/// Starts the ADC. Returns false (and logs why) if it cannot; reading then returns -1.
inline bool init() {
    if (detail::unit != nullptr) return true;
    adc_oneshot_unit_init_cfg_t unit_config = {};
    unit_config.unit_id = ADC_UNIT_1;
    esp_err_t err = adc_oneshot_new_unit(&unit_config, &detail::unit);
    if (err != ESP_OK) {
        ESP_LOGW("battery", "ADC unit not started: %s", esp_err_to_name(err));
        detail::unit = nullptr;
        return false;
    }
    adc_oneshot_chan_cfg_t channel_config = {};
    channel_config.atten = ADC_ATTEN_DB_12;
    channel_config.bitwidth = ADC_BITWIDTH_12;
    err = adc_oneshot_config_channel(detail::unit, kChannel, &channel_config);
    if (err != ESP_OK) {
        ESP_LOGW("battery", "ADC channel not set up: %s", esp_err_to_name(err));
        return false;
    }
    adc_cali_curve_fitting_config_t cali_config = {};
    cali_config.unit_id = ADC_UNIT_1;
    cali_config.chan = kChannel;
    cali_config.atten = ADC_ATTEN_DB_12;
    cali_config.bitwidth = ADC_BITWIDTH_12;
    err = adc_cali_create_scheme_curve_fitting(&cali_config, &detail::cali);
    if (err != ESP_OK) {
        // Still usable, only less exact.
        ESP_LOGW("battery", "ADC calibration unavailable: %s", esp_err_to_name(err));
        detail::cali = nullptr;
    }
    return true;
}

/// The battery voltage in millivolts, or -1 when it cannot be read. Also gives the raw ADC average.
inline int read_mv(int* raw_out = nullptr) {
    if (detail::unit == nullptr && !init()) return -1;
    long raw_sum = 0;
    int good = 0;
    for (int i = 0; i < kSamples; i++) {
        int raw = 0;
        if (adc_oneshot_read(detail::unit, kChannel, &raw) == ESP_OK) {
            raw_sum += raw;
            good++;
        }
    }
    if (good == 0) return -1;
    const int raw = static_cast<int>(raw_sum / good);
    if (raw_out != nullptr) *raw_out = raw;
    int pin_mv = 0;
    if (detail::cali != nullptr) {
        if (adc_cali_raw_to_voltage(detail::cali, raw, &pin_mv) != ESP_OK) return -1;
    } else {
        pin_mv = raw * 3100 / 4095;  // rough, with the 12 dB range, when there is no calibration
    }
    return pin_mv * kDivider;
}

}  // namespace circuit_battery
