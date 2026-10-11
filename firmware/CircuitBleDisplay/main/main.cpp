#include <atomic>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <cctype>
#include <ctime>
#include <mutex>
#include <new>

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_mac.h"
#include "esp_gap_ble_api.h"
#include "esp_gatt_common_api.h"
#include "esp_gatts_api.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_sntp.h"
#include "esp_vfs_fat.h"
#include "esp_wifi.h"

#include "lwip/inet.h"
#include "ping/ping_sock.h"
#include "mbedtls/base64.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdmmc_cmd.h"
#include "driver/gpio.h"
#include "driver/sdmmc_host.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "lvgl.h"
#include "port_display.h"
#include "port_lvgl.h"
#include "port_power.h"
#include "port_codec.h"
#include "circuit_demo_screens.h"
#include "circuit_recording_icon.h"
#include "circuit_crypto.h"
#include "circuit_notes.h"
#include "circuit_selftest_vector.h"
#include "circuit_sync_server.h"

namespace {

constexpr char kDeviceName[] = "Circuit";
constexpr uint16_t kServiceUuid = 0xFFF0;
constexpr uint16_t kTextUuid = 0xFFF1;
constexpr uint16_t kRelayUuid = 0xFFF2;
constexpr size_t kMaxTextBytes = 160;
constexpr char kWifiCommandPrefix[] = "@wifi\n";
constexpr char kWifiScanCommand[] = "@wifi-scan";
constexpr char kHomeStatusCommand[] = "@home\n";
constexpr char kSdMountPath[] = "/sdcard";
constexpr char kSdTestFile[] = "/sdcard/CIRCUIT.TXT";
constexpr uint32_t kAudioSampleRate = 16000;
constexpr uint16_t kAudioChannels = 1;
constexpr uint16_t kCodecCaptureChannels = 2;
constexpr uint16_t kAudioBitsPerSample = 16;
constexpr size_t kAudioBufferBytes = 4096;
// Default cap for a single recording. Kept as one value so a phone setting can
// replace it later. 16 kHz mono 16-bit is ~1.9 MB/min on the SD card.
constexpr uint32_t kMaxRecordingSeconds = 8 * 3600;  // a safety stop; the card fills first (1.9 MB a minute)
constexpr uint32_t kPartSeconds = 60;                // one part of a longer recording
constexpr uint64_t kMinFreeCardBytes = 8ull * 1024 * 1024;  // less than this and a recording stops
// Use the established relay characteristic for binary audio packets too. This
// avoids requiring Android to discard a bonded device's cached GATT table.
constexpr size_t kAudioPacketBytes = 158;
// The upper side button is the BOOT button (GPIO0). The lower GPIO18 button
// is power-related, so it deliberately remains outside the audio controls.
constexpr gpio_num_t kRecordButtonPin = GPIO_NUM_0;
constexpr TickType_t kButtonPollInterval = pdMS_TO_TICKS(20);
constexpr TickType_t kButtonDebounceDelay = pdMS_TO_TICKS(50);
constexpr TickType_t kForceSyncHoldTime = pdMS_TO_TICKS(2000);
// While recording, the same key pauses (or resumes) when held this long.
constexpr TickType_t kPauseHoldTime = pdMS_TO_TICKS(1000);
// A recording left paused this long is saved, so the board is never stuck in a pause.
constexpr int64_t kMaxPausedMs = 600000;
constexpr uint16_t kServiceHandles = 6;

const char *kTag = "Circuit";
QueueHandle_t text_queue;
lv_obj_t *message_label;
lv_obj_t *connection_label;
lv_obj_t *wordmark_image;
lv_obj_t *pairing_code_label;
lv_obj_t *recording_timer_label;
lv_obj_t *recording_icon;  // the animated device icon on the recording screen (64x64)
lv_obj_t *sync_progress_label;
lv_obj_t *busy_icon_obj;  // "cannot record now" (a microphone crossed out), drawn where the sync figure is
lv_obj_t *idle_date_label;
lv_obj_t *idle_time_label;
lv_obj_t *idle_ampm_label;
lv_obj_t *idle_pending_label;
lv_obj_t *idle_done_label;
lv_obj_t *idle_clock_icon;
lv_obj_t *idle_check_icon;
esp_gatt_if_t server_if = ESP_GATT_IF_NONE;
uint16_t service_handle;
uint16_t text_handle;
uint16_t relay_handle;
uint16_t connection_id = UINT16_MAX;
sdmmc_card_t *sd_card = nullptr;
bool audio_ready = false;
// One thing at a time uses the microphone, speaker and the note being sent. It is claimed with
// claim_audio() so two requests arriving together (the key and the app) cannot both win.
std::atomic<bool> audio_busy{false};
TaskHandle_t audio_sync_task_handle = nullptr;
volatile bool recording_active = false;
volatile bool recording_stop_requested = false;
volatile bool recording_paused = false;
volatile uint32_t recording_audio_ms = 0;  // audio recorded so far; a pause does not count
std::atomic<bool> playback_active{false};
std::atomic<bool> playback_stop_requested{false};
std::atomic<uint32_t> playback_audio_ms{0};
enum class DeviceScreen : uint8_t { Idle, Recording, Saved, Syncing, Pairing, Playback };
volatile DeviceScreen active_screen = DeviceScreen::Idle;
volatile TickType_t recording_started_at = 0;
uint32_t pairing_passkey = 0;
bool wifi_connected = false;
// What the header icon and the app's Wi-Fi setup screen show.
enum class WifiUi : uint8_t { None, Connecting, Connected, Failed };
volatile WifiUi wifi_ui = WifiUi::None;
char wifi_ssid[33] = "";
char wifi_detail[48] = "";  // IP address when connected, reason when failed
int wifi_retries = 0;
bool wifi_manual_disconnect = false;  // we asked for the next DISCONNECTED event
bool wifi_auth_failure = false;
int64_t wifi_failed_at_ms = 0;
constexpr int kWifiMaxRetries = 4;
lv_obj_t *icon_wifi_obj;
lv_obj_t *icon_phone_obj;
lv_obj_t *icon_storage_obj;
uint8_t status_icon_frame = 0;
bool wifi_internet_online = false;
bool home_status_received = false;
// True from power-up until the first real screen (home, pairing code, or a state
// such as recording) replaces the boot splash. While it is up, nothing else is
// drawn over the wordmark.
volatile bool boot_splash = true;
volatile bool clock_set = false;
volatile bool ble_encrypted = false;       // bonded phone, link encrypted
volatile uint32_t text_stack_min_bytes = UINT32_MAX;  // least unused stack the command task has had
int boot_reset_reason = -1;               // why the board last restarted (esp_reset_reason)
char last_offer[kMaxTextBytes + 40] = "";   // kept so it can be re-sent until the phone answers
int64_t last_offer_sent_ms = 0;
constexpr int64_t kOfferResendMs = 15000;
constexpr TickType_t kSyncSupervisorInterval = pdMS_TO_TICKS(8000);
bool sntp_started = false;
constexpr time_t kMinValidEpoch = 1704067200;  // 2024-01-01

void send_relay_request(const char *request);
void show_busy_notice();
bool claim_audio() { return !audio_busy.exchange(true); }

// What may interrupt what: a sync comes first, then recording a note; playback comes last and
// gives way to either. A sync is never cut short by a recording, and a recording is never cut
// short by a sync (it is refused, with the crossed-out microphone or "Audio is busy").
//
// If playback is the only thing using the speaker, stops it and waits for it to let go. True
// when the audio is free to use.
bool free_audio_from_playback() {
    if (!audio_busy) return true;
    if (!playback_active.load()) return false;
    playback_stop_requested = true;
    for (int waited_ms = 0; audio_busy && waited_ms < 3000; waited_ms += 20) vTaskDelay(pdMS_TO_TICKS(20));
    return !audio_busy;
}
esp_err_t send_audio_data(const uint8_t *data, size_t length);

struct TextMessage {
    char value[kMaxTextBytes + 1];
};

#pragma pack(push, 1)
struct WavHeader {
    char riff[4] = {'R', 'I', 'F', 'F'};
    uint32_t file_size = 0;
    char wave[4] = {'W', 'A', 'V', 'E'};
    char format[4] = {'f', 'm', 't', ' '};
    uint32_t format_size = 16;
    uint16_t audio_format = 1;
    uint16_t channels = kAudioChannels;
    uint32_t sample_rate = kAudioSampleRate;
    uint32_t byte_rate = kAudioSampleRate * kAudioChannels * kAudioBitsPerSample / 8;
    uint16_t block_align = kAudioChannels * kAudioBitsPerSample / 8;
    uint16_t bits_per_sample = kAudioBitsPerSample;
    char data[4] = {'d', 'a', 't', 'a'};
    uint32_t data_size = 0;
};
#pragma pack(pop)

esp_ble_adv_params_t adv_params = {
    .adv_int_min = 0x20,
    .adv_int_max = 0x40,
    .adv_type = ADV_TYPE_IND,
    .own_addr_type = BLE_ADDR_TYPE_PUBLIC,
    .channel_map = ADV_CHNL_ALL,
    .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

esp_ble_adv_data_t adv_data = {
    .set_scan_rsp = false,
    .include_name = true,
    .include_txpower = false,
    .min_interval = 0x0006,
    .max_interval = 0x0010,
    .appearance = 0,
    .manufacturer_len = 0,
    .p_manufacturer_data = nullptr,
    .service_data_len = 0,
    .p_service_data = nullptr,
    // ESP-IDF's structured advertising API expects a 128-bit UUID here.
    // The 16-bit service remains discoverable after connecting; advertise the
    // name only so Android scanners can find Circuit reliably.
    .service_uuid_len = 0,
    .p_service_uuid = nullptr,
    .flag = ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT,
};

void flush_display(lv_display_t *display, const lv_area_t *area, uint8_t *color_p) {
    uint16_t *pixels = reinterpret_cast<uint16_t *>(color_p);
    EPD_Clear();
    for (int y = area->y1; y <= area->y2; ++y) {
        for (int x = area->x1; x <= area->x2; ++x) {
            const uint8_t color = (*pixels < 0x7fff) ? DRIVER_COLOR_BLACK : DRIVER_COLOR_WHITE;
            EPD_DrawColorPixel(x, y, color);
            ++pixels;
        }
    }
    EPD_DisplayPart();
    lv_disp_flush_ready(display);
}

struct ScreenTimeout {
    DeviceScreen expected;
    uint32_t delay_ms;
};

void show_device_screen(DeviceScreen screen);

// Date, clock and note counts stay on screen in every state (see
// prototypes/circuit-epaper-states). They only appear once the phone has
// supplied real values; until then they show dashes. The pairing screen
// keeps its baked "PAIR CODE" header in place of the date.
void apply_persistent_labels(DeviceScreen screen) {
    if (boot_splash) return;
    // Moving objects to the foreground redraws the screen, so only do it when the
    // screen actually changed.
    static int applied = -1;
    if (applied == static_cast<int>(screen)) return;
    applied = static_cast<int>(screen);
    const bool show = true;
    const auto set_visible = [](lv_obj_t *label, bool visible) {
        if (visible) lv_obj_clear_flag(label, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(label, LV_OBJ_FLAG_HIDDEN);
    };
    // The pairing screen is a dedicated layout with no persistent info.
    const bool persistent = show && screen != DeviceScreen::Pairing;
    set_visible(idle_date_label, persistent);
    set_visible(idle_time_label, persistent);
    set_visible(idle_ampm_label, persistent);
    set_visible(idle_pending_label, persistent);
    set_visible(idle_done_label, persistent);
    set_visible(idle_clock_icon, persistent);
    set_visible(idle_check_icon, persistent);
    // Labels must sit above the full-screen artwork.
    lv_obj_move_foreground(idle_date_label);
    lv_obj_move_foreground(idle_time_label);
    lv_obj_move_foreground(idle_ampm_label);
    lv_obj_move_foreground(idle_pending_label);
    lv_obj_move_foreground(idle_done_label);
    lv_obj_move_foreground(idle_clock_icon);
    lv_obj_move_foreground(idle_check_icon);
}

// Makes local time follow the phone's UTC offset.
void apply_utc_offset(int offset_minutes) {
    char tz[24];
    const int east = offset_minutes < 0 ? -offset_minutes : offset_minutes;
    // POSIX TZ offsets are inverted: UTC+5:30 is written "UTC-5:30".
    snprintf(tz, sizeof(tz), "UTC%c%d:%02d", offset_minutes >= 0 ? '-' : '+', east / 60, east % 60);
    setenv("TZ", tz, 1);
    tzset();
}

// Sets the system clock once. The phone's UTC offset becomes the local zone.
void set_clock_from_phone(time_t epoch, int offset_minutes) {
    if (epoch < kMinValidEpoch) return;
    apply_utc_offset(offset_minutes);
    timeval tv = {.tv_sec = epoch, .tv_usec = 0};
    settimeofday(&tv, nullptr);
    clock_set = true;
}

// Shows a 24-hour time as 12-hour "H:MM" with a small AM/PM beside it.
// Requires the LVGL lock.
void set_clock_labels(int hour24, int minute) {
    char text[8];
    const int hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    snprintf(text, sizeof(text), "%d:%02d", hour12, minute);
    lv_label_set_text(idle_time_label, text);
    lv_label_set_text(idle_ampm_label, hour24 < 12 ? "AM" : "PM");
    lv_obj_update_layout(idle_time_label);
    lv_obj_align_to(idle_ampm_label, idle_time_label, LV_ALIGN_OUT_RIGHT_BOTTOM, 3, -7);
}

// Requires the LVGL lock.
// Lays the counts out right to left so the icons follow the digits:
// [clock]3 [check]9. Requires the LVGL lock.
void layout_count_labels() {
    lv_obj_update_layout(idle_done_label);
    lv_obj_align_to(idle_check_icon, idle_done_label, LV_ALIGN_OUT_LEFT_MID, -3, 0);
    lv_obj_align_to(idle_pending_label, idle_check_icon, LV_ALIGN_OUT_LEFT_MID, -9, 0);
    lv_obj_update_layout(idle_pending_label);
    lv_obj_align_to(idle_clock_icon, idle_pending_label, LV_ALIGN_OUT_LEFT_MID, -3, 0);
    lv_obj_update_layout(idle_clock_icon);
    ESP_LOGI(kTag, "Counts layout: clock x=%d | pending x=%d w=%d y=%d | check x=%d | done x=%d w=%d y=%d h=%d",
        (int)lv_obj_get_x(idle_clock_icon), (int)lv_obj_get_x(idle_pending_label), (int)lv_obj_get_width(idle_pending_label),
        (int)lv_obj_get_y(idle_pending_label), (int)lv_obj_get_x(idle_check_icon), (int)lv_obj_get_x(idle_done_label),
        (int)lv_obj_get_width(idle_done_label), (int)lv_obj_get_y(idle_done_label), (int)lv_obj_get_height(idle_done_label));
}

// Requires the LVGL lock.
void set_count_labels(int pending, int done) {
    char text[8];
    snprintf(text, sizeof(text), "%d", pending);
    lv_label_set_text(idle_pending_label, text);
    snprintf(text, sizeof(text), "%d", done);
    lv_label_set_text(idle_done_label, text);
    layout_count_labels();
}

// Draws the current local time and date on the home screen. Requires the LVGL lock.
void show_local_time(time_t now) {
    tm local = {};
    localtime_r(&now, &local);
    char date_text[16];
    strftime(date_text, sizeof(date_text), "%a %d %b", &local);
    for (char *c = date_text; *c; ++c) *c = toupper(static_cast<unsigned char>(*c));
    set_clock_labels(local.tm_hour, local.tm_min);
    lv_label_set_text(idle_date_label, date_text);
}

// The last values the phone sent, kept in flash so the home screen is complete
// straight after power-up instead of showing dashes until the phone reconnects.
struct SavedHome {
    int32_t pending;
    int32_t done;
    int32_t offset_minutes;
};
constexpr char kHomeNamespace[] = "home";
constexpr char kHomeKey[] = "last";
SavedHome saved_home = {-1, -1, 0};

bool load_home_snapshot(SavedHome *home) {
    nvs_handle_t handle;
    if (nvs_open(kHomeNamespace, NVS_READONLY, &handle) != ESP_OK) return false;
    size_t size = sizeof(*home);
    const bool ok = nvs_get_blob(handle, kHomeKey, home, &size) == ESP_OK && size == sizeof(*home) &&
                    home->pending >= 0 && home->done >= 0;
    nvs_close(handle);
    return ok;
}

// Only writes when something changed, so flash wear stays negligible.
void save_home_snapshot(const SavedHome &home) {
    if (home.pending == saved_home.pending && home.done == saved_home.done &&
        home.offset_minutes == saved_home.offset_minutes) {
        return;
    }
    nvs_handle_t handle;
    if (nvs_open(kHomeNamespace, NVS_READWRITE, &handle) != ESP_OK) return;
    if (nvs_set_blob(handle, kHomeKey, &home, sizeof(home)) == ESP_OK && nvs_commit(handle) == ESP_OK) {
        saved_home = home;
    }
    nvs_close(handle);
}

// Fills the home screen from what the board already knows, before it is first
// drawn: the saved note counts and time zone, and the clock when it kept running
// through a restart. Anything unknown stays as a dash until the phone connects.
void restore_home_screen() {
    SavedHome home = {};
    const bool have_saved = load_home_snapshot(&home);
    if (have_saved) {
        saved_home = home;
        apply_utc_offset(home.offset_minutes);
    }
    const time_t now = time(nullptr);
    const bool clock_kept = now >= kMinValidEpoch;  // lost only when power is cut
    if (clock_kept) clock_set = true;
    if (!Lvgl_lock(-1)) return;
    if (have_saved) set_count_labels(home.pending, home.done);
    if (clock_kept) show_local_time(now);
    Lvgl_unlock();
    ESP_LOGI(kTag, "Home restored: counts=%s clock=%s", have_saved ? "saved" : "none", clock_kept ? "kept" : "unknown");
}

void update_home_status(const char *value) {
    char buffer[kMaxTextBytes + 1];
    strncpy(buffer, value, sizeof(buffer) - 1);
    buffer[sizeof(buffer) - 1] = '\0';
    char *save = nullptr;
    strtok_r(buffer, "\n", &save);  // @home
    const char *time = strtok_r(nullptr, "\n", &save);
    const char *date = strtok_r(nullptr, "\n", &save);
    const char *counts = strtok_r(nullptr, "\n", &save);
    const char *epoch = strtok_r(nullptr, "\n", &save);
    const char *offset = strtok_r(nullptr, "\n", &save);
    if (time == nullptr || date == nullptr || counts == nullptr) return;
    // First time source wins; after that Circuit keeps time on its own.
    if (!clock_set && epoch != nullptr && offset != nullptr) {
        set_clock_from_phone(strtoll(epoch, nullptr, 10), atoi(offset));
    }
    // The phone repeats this message often. Touching the labels redraws the whole
    // e-paper, so do nothing when it matches what is already shown.
    int hour = 0, minute = 0, pending = 0, done = 0;
    const bool time_ok = sscanf(time, "%d:%d", &hour, &minute) == 2;
    const bool counts_ok = sscanf(counts, "%d %*[^0-9]%d", &pending, &done) == 2;
    static int shown_pending = -1, shown_done = -1, shown_clock = -1;
    const int clock_key = hour * 60 + minute;
    if (counts_ok && offset != nullptr) {
        save_home_snapshot({pending, done, atoi(offset)});
    }
    const bool same = home_status_received && counts_ok && pending == shown_pending && done == shown_done &&
                      (clock_set || (time_ok && clock_key == shown_clock));
    if (same) return;
    if (!Lvgl_lock(-1)) return;
    home_status_received = true;
    if (!clock_set) {
        if (time_ok) set_clock_labels(hour, minute);
        lv_label_set_text(idle_date_label, date);
        shown_clock = clock_key;
    }
    // The phone sends "<pending> · <done>"; the separator is not drawn.
    if (counts_ok) {
        set_count_labels(pending, done);
        shown_pending = pending;
        shown_done = done;
    }
    ESP_LOGI(kTag, "Home status: counts=%d/%d clock_set=%d", pending, done, clock_set ? 1 : 0);
    apply_persistent_labels(active_screen);
    Lvgl_unlock();
}

void screen_timeout_task(void *argument) {
    const ScreenTimeout timeout = *static_cast<ScreenTimeout *>(argument);
    delete static_cast<ScreenTimeout *>(argument);
    vTaskDelay(pdMS_TO_TICKS(timeout.delay_ms));
    if (active_screen == timeout.expected &&
        !(timeout.expected == DeviceScreen::Playback && playback_active.load())) {
        show_device_screen(DeviceScreen::Idle);
    }
    vTaskDelete(nullptr);
}

void return_to_idle_after(DeviceScreen expected, uint32_t delay_ms) {
    auto *timeout = new ScreenTimeout{expected, delay_ms};
    if (timeout != nullptr) {
        xTaskCreate(screen_timeout_task, "screen_timeout", 3072, timeout, 2, nullptr);
    }
}

void update_message(const char *message) {
    if (!Lvgl_lock(-1)) {
        return;
    }
    lv_label_set_text(message_label, message);
    Lvgl_unlock();
}

void show_device_screen(DeviceScreen screen) {
    static constexpr const lv_image_dsc_t *kScreens[] = {
        &circuit_idle_screen,
        &circuit_record_screen,
        &circuit_saved_screen,
        &circuit_sync_screen,
        &circuit_pair_screen,
        &circuit_idle_screen,  // playback uses live labels, with the artwork hidden
    };
    if (!Lvgl_lock(-1)) {
        return;
    }
    active_screen = screen;
    boot_splash = false;
    if (screen == DeviceScreen::Recording) {
        recording_started_at = xTaskGetTickCount();
    }
    lv_obj_add_flag(connection_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(message_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(pairing_code_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(recording_timer_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(recording_icon, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(sync_progress_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(busy_icon_obj, LV_OBJ_FLAG_HIDDEN);
    lv_img_set_src(wordmark_image, kScreens[static_cast<size_t>(screen)]);
    lv_obj_center(wordmark_image);
    apply_persistent_labels(screen);
    if (screen == DeviceScreen::Recording) {
        lv_label_set_text(recording_timer_label, "00:00");
        lv_obj_clear_flag(recording_timer_label, LV_OBJ_FLAG_HIDDEN);
        lv_img_set_src(recording_icon, circuit_recording_frame(0));
        lv_obj_clear_flag(recording_icon, LV_OBJ_FLAG_HIDDEN);
    } else if (screen == DeviceScreen::Syncing) {
        lv_label_set_text(sync_progress_label, "0%");
        lv_obj_clear_flag(sync_progress_label, LV_OBJ_FLAG_HIDDEN);
    }
    if (screen == DeviceScreen::Playback) {
        lv_obj_add_flag(wordmark_image, LV_OBJ_FLAG_HIDDEN);
        lv_obj_align(message_label, LV_ALIGN_TOP_MID, 0, 94);
        lv_obj_clear_flag(message_label, LV_OBJ_FLAG_HIDDEN);
        lv_obj_move_foreground(message_label);
        lv_label_set_text(recording_timer_label, "00:00");
        lv_obj_set_width(recording_timer_label, 176);
        lv_obj_set_style_text_align(recording_timer_label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_align(recording_timer_label, LV_ALIGN_BOTTOM_MID, 0, -22);
        lv_obj_clear_flag(recording_timer_label, LV_OBJ_FLAG_HIDDEN);
        lv_obj_move_foreground(recording_timer_label);
    } else {
        lv_obj_align(message_label, LV_ALIGN_BOTTOM_MID, 0, -12);
        lv_obj_set_width(recording_timer_label, 84);
        lv_obj_set_style_text_align(recording_timer_label, LV_TEXT_ALIGN_LEFT, 0);
        lv_obj_align(recording_timer_label, LV_ALIGN_TOP_LEFT, 116, 124);
        lv_obj_clear_flag(wordmark_image, LV_OBJ_FLAG_HIDDEN);
    }
    Lvgl_unlock();
}

void demo_animation_task(void *) {
    size_t sync_frame = 0;
    while (true) {
        if (active_screen == DeviceScreen::Recording && wordmark_image != nullptr && recording_icon != nullptr) {
            if (Lvgl_lock(-1)) {
                // Re-check under the lock: the screen may have changed while waiting for it.
                if (active_screen == DeviceScreen::Recording) {
                    // Four stepped frames (waveform changes, the dot alternates filled and hollow)
                    // at the e-paper's cadence; it shows recording is on, not the sound level.
                    // The timer counts recorded audio, so it stops during a pause: the picture
                    // freezes and the time blinks.
                    const uint32_t audio_ms = recording_audio_ms;
                    lv_img_set_src(recording_icon, circuit_recording_frame(audio_ms));
                    const uint32_t elapsed = audio_ms / 1000;
                    char elapsed_text[12];
                    snprintf(elapsed_text, sizeof(elapsed_text), "%02lu:%02lu",
                        static_cast<unsigned long>(elapsed / 60),
                        static_cast<unsigned long>(elapsed % 60));
                    lv_label_set_text(recording_timer_label, elapsed_text);
                    static bool blink_off = false;
                    blink_off = recording_paused && !blink_off;
                    if (blink_off) {
                        lv_obj_add_flag(recording_timer_label, LV_OBJ_FLAG_HIDDEN);
                    } else {
                        lv_obj_clear_flag(recording_timer_label, LV_OBJ_FLAG_HIDDEN);
                    }
                    lv_obj_clear_flag(recording_icon, LV_OBJ_FLAG_HIDDEN);
                }
                Lvgl_unlock();
            }
            vTaskDelay(pdMS_TO_TICKS(circuit_recording_frame_ms));
        } else if (active_screen == DeviceScreen::Syncing && wordmark_image != nullptr) {
            // The e-paper cannot spin smoothly, so step the refresh icon
            // through its rotations instead.
            static constexpr const lv_image_dsc_t *kSyncFrames[] = {
                &circuit_sync_screen,   &circuit_sync_1_screen, &circuit_sync_2_screen,
                &circuit_sync_3_screen, &circuit_sync_4_screen, &circuit_sync_5_screen,
            };
            sync_frame = (sync_frame + 1) % (sizeof(kSyncFrames) / sizeof(kSyncFrames[0]));
            if (Lvgl_lock(-1)) {
                if (active_screen == DeviceScreen::Syncing) {
                    lv_img_set_src(wordmark_image, kSyncFrames[sync_frame]);
                }
                Lvgl_unlock();
            }
            vTaskDelay(pdMS_TO_TICKS(700));
        } else if (active_screen == DeviceScreen::Playback && playback_active.load()) {
            if (Lvgl_lock(-1)) {
                if (active_screen == DeviceScreen::Playback && playback_active.load()) {
                    const uint32_t seconds = playback_audio_ms.load() / 1000;
                    char text[16];
                    snprintf(text, sizeof(text), "%02lu:%02lu",
                        static_cast<unsigned long>(seconds / 60), static_cast<unsigned long>(seconds % 60));
                    lv_label_set_text(recording_timer_label, text);
                }
                Lvgl_unlock();
            }
            vTaskDelay(pdMS_TO_TICKS(1000));
        } else {
            sync_frame = 0;
            vTaskDelay(pdMS_TO_TICKS(150));
        }
    }
}

void show_pairing_code() {
    if (!Lvgl_lock(-1)) return;
    char code[16];
    const unsigned long passkey = static_cast<unsigned long>(pairing_passkey % 1000000);
    snprintf(code, sizeof(code), "%03lu %03lu", passkey / 1000, passkey % 1000);
    active_screen = DeviceScreen::Pairing;
    boot_splash = false;
    lv_obj_add_flag(connection_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(message_label, LV_OBJ_FLAG_HIDDEN);
    lv_img_set_src(wordmark_image, &circuit_pair_screen);
    lv_label_set_text(pairing_code_label, code);
    lv_obj_clear_flag(pairing_code_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(recording_timer_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(recording_icon, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(sync_progress_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(busy_icon_obj, LV_OBJ_FLAG_HIDDEN);
    apply_persistent_labels(DeviceScreen::Pairing);
    lv_obj_clear_flag(wordmark_image, LV_OBJ_FLAG_HIDDEN);
    Lvgl_unlock();
}

void update_connection_status(const char *status) {
    if (!Lvgl_lock(-1)) {
        return;
    }
    lv_label_set_text(connection_label, status);
    Lvgl_unlock();
}

void show_relay_disconnected() {
    update_connection_status(wifi_connected
        ? (wifi_internet_online
            ? "Wi-Fi: connected\nInternet: online\nPhone relay: disconnected"
            : "Wi-Fi: connected\nInternet: offline\nPhone relay: disconnected")
        : "Wi-Fi: offline\nInternet: offline\nPhone relay: disconnected");
}

void update_storage_status(const char *status) {
    if (!Lvgl_lock(-1)) {
        return;
    }
    lv_label_set_text(message_label, status);
    Lvgl_unlock();
}

void init_sd_card() {
    esp_vfs_fat_sdmmc_mount_config_t mount_config = {
        .format_if_mount_failed = false,
        .max_files = 5,
        .allocation_unit_size = 16 * 1024,
    };

    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.max_freq_khz = SDMMC_FREQ_HIGHSPEED;

    sdmmc_slot_config_t slot_config = SDMMC_SLOT_CONFIG_DEFAULT();
    slot_config.width = 1;
    slot_config.clk = GPIO_NUM_39;
    slot_config.cmd = GPIO_NUM_41;
    slot_config.d0 = GPIO_NUM_40;
    const esp_err_t mount_status = esp_vfs_fat_sdmmc_mount(
        kSdMountPath, &host, &slot_config, &mount_config, &sd_card);
    if (mount_status != ESP_OK || sd_card == nullptr) {
        ESP_LOGW(kTag, "MicroSD mount failed: %s", esp_err_to_name(mount_status));
        update_storage_status("MicroSD: unavailable\nInsert a FAT32 card");
        return;
    }

    constexpr char kTestContents[] = "Circuit storage verified\n";
    FILE *file = fopen(kSdTestFile, "w");
    if (file == nullptr || fputs(kTestContents, file) < 0) {
        if (file != nullptr) fclose(file);
        ESP_LOGW(kTag, "MicroSD write test failed");
        update_storage_status("MicroSD: mounted\nWrite test failed");
        return;
    }
    fclose(file);

    char readback[sizeof(kTestContents)] = {};
    file = fopen(kSdTestFile, "r");
    const bool verified = file != nullptr &&
        fread(readback, 1, sizeof(kTestContents) - 1, file) == sizeof(kTestContents) - 1 &&
        strcmp(readback, kTestContents) == 0;
    if (file != nullptr) fclose(file);

    if (verified) {
        ESP_LOGI(kTag, "MicroSD mounted and read/write test passed");
        circuit_notes::init();
        ESP_LOGI(kTag, "Notes on card: %u unsynced", static_cast<unsigned>(circuit_notes::count_unsynced()));
        circuit_notes::for_each_wav([](uint32_t id) {
            circuit_notes::Note note;
            if (circuit_notes::describe(id, &note)) {
                ESP_LOGI(kTag, "  note %lu: %lu bytes, recorded %lld, %s", static_cast<unsigned long>(note.id),
                    static_cast<unsigned long>(note.bytes), static_cast<long long>(note.recorded),
                    note.synced ? "synced" : "waiting");
            }
        });
        update_storage_status("MicroSD: ready\nStorage verified");
    } else {
        ESP_LOGW(kTag, "MicroSD readback test failed");
        update_storage_status("MicroSD: mounted\nRead test failed");
    }
}

void finish_audio_task() {
    // The task deletes itself below, so a handle left behind would point at nothing.
    audio_sync_task_handle = nullptr;
    recording_paused = false;
    recording_active = false;
    playback_active = false;
    audio_busy = false;
    vTaskDelete(nullptr);
}

void report_audio_status(const char *status) {
    if (strncmp(status, "Playback", 8) == 0 || strncmp(status, "Playing", 7) == 0) {
        ESP_LOGI(kTag, "Playback status: %s", status);
    }
    char message[kMaxTextBytes + 1] = "@audio-status\n";
    strncat(message, status, sizeof(message) - strlen(message) - 1);
    send_relay_request(message);
}

// ---- encrypted notes ---------------------------------------------------------
// Notes are sealed as they are recorded (circuit_crypto.h) with a key that exists
// only on this board and on the phone it is paired with. The key is made the first
// time the board is paired and is destroyed, with every note, on a re-pair.

circuit_secure::Key note_key = {};
volatile bool note_key_ready = false;
bool crypto_self_test_ok = false;

bool run_crypto_self_test_with(uint8_t *sealed, uint8_t *opened, uint8_t *damaged);

// Proves at every start that this build's crypto matches the reference vectors the
// Android app is also tested against. If it does not, nothing is recorded.
bool run_crypto_self_test() {
    // These buffers are only needed for a moment at start-up, so they are borrowed from
    // the heap and given back, rather than kept as static arrays: internal RAM on this
    // board is so tight that 1.5 KB of permanent buffers mattered.
    uint8_t *scratch = static_cast<uint8_t *>(malloc(3 * 512));
    if (scratch == nullptr) return false;
    uint8_t *sealed = scratch, *opened = scratch + 512, *damaged = scratch + 1024;
    const bool ok = run_crypto_self_test_with(sealed, opened, damaged);
    memset(scratch, 0, 3 * 512);
    free(scratch);
    return ok;
}

bool run_crypto_self_test_with(uint8_t *sealed, uint8_t *opened, uint8_t *damaged) {
    circuit_secure::Key key = {};
    memcpy(key.bytes, kVectorMasterKey, sizeof(kVectorMasterKey));
    key.id = kVectorKeyId;
    const uint8_t *pcm[] = {kVectorPcm0, kVectorPcm1};
    const unsigned pcm_len[] = {kVectorPcm0Len, kVectorPcm1Len};
    const uint8_t *file[] = {kVectorFile0, kVectorFile1};
    const unsigned file_len[] = {kVectorFile0Len, kVectorFile1Len};
    for (unsigned i = 0; i < kVectorCases; ++i) {
        // Sealing must produce exactly the reference file.
        const size_t made = circuit_secure::seal_buffer(key, kVectorNoteId, 16000, 1, 16, kVectorChunk, pcm[i],
                                                        pcm_len[i], sealed, 512);
        if (made != file_len[i] || memcmp(sealed, file[i], made) != 0) return false;
        // The reference file must open to exactly the reference audio.
        size_t length = 0;
        if (!circuit_secure::open_buffer(key, file[i], file_len[i], opened, 512, &length) ||
            length != pcm_len[i] || memcmp(opened, pcm[i], length) != 0) {
            return false;
        }
        // And a single flipped bit must be caught.
        memcpy(damaged, file[i], file_len[i]);
        damaged[file_len[i] - 1] ^= 1;
        if (circuit_secure::open_buffer(key, damaged, file_len[i], opened, 512, &length)) return false;
    }
    return true;
}

// Makes the key the first time the board is paired. A board that is not paired has
// none, so it records nothing: there would be no phone able to read it.
void ensure_note_key() {
    // Called from start-up and from the BLE task; without the lock both could find no
    // key and each make one (seen: two keys in flash on a board paired once).
    static std::mutex lock;
    std::lock_guard<std::mutex> guard(lock);
    if (note_key_ready) return;
    if (circuit_secure::create_key(&note_key)) {
        note_key_ready = true;
        ESP_LOGI(kTag, "Created the notes key (id %08lx)", static_cast<unsigned long>(note_key.id));
    } else {
        ESP_LOGE(kTag, "Could not store the notes key");
    }
}

// A paired phone asks for the key. Only an encrypted, bonded link can write this
// command or receive the answer (both characteristics require encryption), so the
// key never crosses the air in the clear. Reply: "@sec-key\n1\n<id hex>\n<base64>".
void send_note_key_to_phone(const char *request) {
    const unsigned long version = strtoul(request + strlen("@sec-hello\n"), nullptr, 10);
    char reply[kMaxTextBytes + 1];
    if (!ble_encrypted) {
        snprintf(reply, sizeof(reply), "@sec-none\nnot encrypted");
    } else if (version < 1) {
        snprintf(reply, sizeof(reply), "@sec-none\nunsupported");
    } else if (!note_key_ready) {
        snprintf(reply, sizeof(reply), "@sec-none\nno key");
    } else {
        char encoded[64] = {};
        size_t length = 0;
        mbedtls_base64_encode(reinterpret_cast<unsigned char *>(encoded), sizeof(encoded) - 1, &length,
                              note_key.bytes, sizeof(note_key.bytes));
        snprintf(reply, sizeof(reply), "@sec-key\n1\n%08lx\n%s", static_cast<unsigned long>(note_key.id), encoded);
        memset(encoded, 0, sizeof(encoded));
        ESP_LOGI(kTag, "Sent the notes key to the phone (id %08lx)", static_cast<unsigned long>(note_key.id));
    }
    send_relay_request(reply);
    memset(reply, 0, sizeof(reply));
}


// Free room on the card, in bytes (0 if it cannot be read).
uint64_t sd_free_bytes() {
    uint64_t total = 0, free_bytes = 0;
    return esp_vfs_fat_info(kSdMountPath, &total, &free_bytes) == ESP_OK ? free_bytes : 0;
}

// A recording is stored as one-minute parts: ordinary encrypted notes with consecutive numbers,
// each marked (circuit_notes.h, .PRT) with the number of the recording's first part, its own
// position and whether it is the last. The phone joins them into one note. A short recording
// is a single plain note, exactly as before. The card's free room is the limit, not the clock.
void record_audio_task(void *argument) {
    const uint32_t seconds = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(argument));
    if (!audio_ready || sd_card == nullptr) {
        update_storage_status("MicroSD required\nCannot record audio");
        report_audio_status("Recording failed: MicroSD unavailable");
        finish_audio_task();
        return;
    }
    if (sd_free_bytes() < kMinFreeCardBytes) {
        update_storage_status("Card is full\nFree some space");
        report_audio_status("Recording failed: the card is full");
        finish_audio_task();
        return;
    }

    recording_audio_ms = 0;
    recording_paused = false;
    show_device_screen(DeviceScreen::Recording);

    char note_path[48];
    const uint32_t first_id = circuit_notes::allocate_id();
    uint32_t current_id = first_id;
    uint32_t previous_id = 0;  // the part before the current one, once there is one
    uint32_t part = 1;
    uint32_t part_bytes = 0;
    circuit_notes::path_for(current_id, "ENC", note_path, sizeof(note_path));
    // The sealing buffers are too big for this task's stack, so the writer lives on the heap.
    auto *writer = new (std::nothrow) circuit_secure::Writer();
    if (writer == nullptr || !writer->open(note_path, note_key, current_id, kAudioSampleRate, kAudioChannels, kAudioBitsPerSample)) {
        delete writer;
        update_storage_status("Audio record failed\nCannot create file");
        report_audio_status("Recording failed: cannot create file");
        finish_audio_task();
        return;
    }

    WavHeader header{};  // only for the audio format constants
    uint8_t *buffer = static_cast<uint8_t *>(heap_caps_malloc(kAudioBufferBytes, MALLOC_CAP_SPIRAM));
    if (buffer == nullptr) {
        writer->abort();
        delete writer;
        remove(note_path);
        update_storage_status("Audio record failed\nNot enough memory");
        report_audio_status("Recording failed: memory unavailable");
        finish_audio_task();
        return;
    }

    const uint32_t target_bytes = seconds * header.byte_rate;
    const uint32_t part_limit_bytes = kPartSeconds * header.byte_rate;
    uint32_t recorded_bytes = 0;
    update_storage_status("Recording audio…\nPlease speak near Circuit");
    report_audio_status("Recording started: speak near Circuit");
    // Wall-clock time spent recording (not paused) against the audio that came back. A gap
    // between the two means samples were lost.
    const int64_t started_us = esp_timer_get_time();
    int64_t paused_us = 0;
    int64_t pause_began_us = 0;
    int64_t longest_join_us = 0;  // closing one part and opening the next, where audio could be lost
    bool writer_open = true;      // false once the current part has been closed at a join
    bool card_full = false;
    bool close_failed = false;  // a part could not be sealed at a join
    while (recorded_bytes < target_bytes && !recording_stop_requested) {
        const size_t mono_bytes = (target_bytes - recorded_bytes) < (kAudioBufferBytes / kCodecCaptureChannels)
            ? target_bytes - recorded_bytes : (kAudioBufferBytes / kCodecCaptureChannels);
        const size_t stereo_bytes = mono_bytes * kCodecCaptureChannels;
        // The microphone keeps running through a pause so it resumes without a gap in the
        // hardware buffers; what it hears while paused is thrown away.
        if (Codec_RecordData(buffer, stereo_bytes) != ESP_OK) {
            break;
        }
        if (recording_paused) {
            if (pause_began_us == 0) pause_began_us = esp_timer_get_time();
            if ((esp_timer_get_time() - pause_began_us) / 1000 > kMaxPausedMs) {
                ESP_LOGW(kTag, "Paused for too long: saving the recording");
                recording_paused = false;
                break;
            }
            continue;
        }
        if (pause_began_us != 0) {
            paused_us += esp_timer_get_time() - pause_began_us;
            pause_began_us = 0;
        }
        // The board codec delivers stereo 16-bit samples. Voice notes retain
        // the first microphone channel only, halving both storage and BLE sync.
        auto *samples = reinterpret_cast<int16_t *>(buffer);
        for (size_t frame = 0; frame < mono_bytes / sizeof(int16_t); ++frame) {
            samples[frame] = samples[frame * kCodecCaptureChannels];
        }
        if (part_bytes >= part_limit_bytes) {
            // A minute is full: close this part and carry straight on in the next, with the
            // audio already read going into it. The next part is only opened when there is
            // audio for it, so a recording never ends in an empty part.
            const int64_t join_began_us = esp_timer_get_time();
            const bool closed = writer->finish();
            writer_open = false;
            if (!closed) {
                close_failed = true;
                break;
            }
            circuit_notes::write_group(current_id, {first_id, part, false});
            previous_id = current_id;
            if (sd_free_bytes() < kMinFreeCardBytes) {
                card_full = true;
                break;
            }
            const uint32_t next_id = circuit_notes::allocate_id();
            char next_path[48];
            circuit_notes::path_for(next_id, "ENC", next_path, sizeof(next_path));
            if (!writer->open(next_path, note_key, next_id, kAudioSampleRate, kAudioChannels, kAudioBitsPerSample)) {
                break;  // the closed part is the last one; what was recorded is kept
            }
            writer_open = true;
            current_id = next_id;
            ++part;
            part_bytes = 0;
            memcpy(note_path, next_path, sizeof(note_path));
            // Marked as soon as it exists: if the power fails, the recording is still known as parts.
            circuit_notes::write_group(current_id, {first_id, part, false});
            const int64_t join_us = esp_timer_get_time() - join_began_us;
            if (join_us > longest_join_us) longest_join_us = join_us;
        }
        if (!writer->append(buffer, mono_bytes)) break;
        recorded_bytes += mono_bytes;
        part_bytes += mono_bytes;
        recording_audio_ms = static_cast<uint32_t>(static_cast<uint64_t>(recorded_bytes) * 1000 / header.byte_rate);
    }
    if (pause_began_us != 0) paused_us += esp_timer_get_time() - pause_began_us;
    {
        const int64_t wall_ms = (esp_timer_get_time() - started_us - paused_us) / 1000;
        const int64_t audio_ms = static_cast<int64_t>(recorded_bytes) * 1000 / header.byte_rate;
        ESP_LOGW(kTag, "RECSTAT audio=%lld ms, recording time=%lld ms, lost=%lld ms, paused=%lld ms, parts=%lu, longest join=%lld ms",
            static_cast<long long>(audio_ms), static_cast<long long>(wall_ms), static_cast<long long>(wall_ms - audio_ms),
            static_cast<long long>(paused_us / 1000), static_cast<unsigned long>(part),
            static_cast<long long>(longest_join_us / 1000));
    }
    heap_caps_free(buffer);

    // Seals the last chunk. A part that cannot be finished is not kept as if it were fine: the
    // recording then ends at the part before it.
    uint32_t last_id = current_id;
    uint32_t parts = part;
    bool whole_recording_lost = false;
    const auto drop_current_part = [&]() {
        circuit_notes::remove_note(current_id);
        if (part > 1) {
            last_id = previous_id;
            parts = part - 1;
        } else {
            whole_recording_lost = true;
        }
    };
    if (writer_open) {
        if (part_bytes == 0 && part > 1) {
            writer->abort();  // opened for audio that never came
            drop_current_part();
        } else if (!writer->finish()) {
            drop_current_part();
        }
    } else if (close_failed) {
        drop_current_part();
    }
    delete writer;
    if (whole_recording_lost) {
        update_storage_status("Audio record failed\nCould not save note");
        report_audio_status("Recording failed: could not save the note");
        finish_audio_task();
        return;
    }
    if (parts > 1) {
        circuit_notes::write_group(last_id, {first_id, parts, true});
    } else {  // a single part is a plain note
        char marker[48];
        circuit_notes::path_for(first_id, "PRT", marker, sizeof(marker));
        remove(marker);
    }
    const uint32_t saved_parts = parts;

    ESP_LOGI(kTag, "Saved recording %lu as %lu part(s), last part %s (%lu bytes of audio, encrypted)",
        static_cast<unsigned long>(first_id), static_cast<unsigned long>(saved_parts), note_path,
        static_cast<unsigned long>(recorded_bytes));
    const bool completed = recorded_bytes == target_bytes;
    show_device_screen(DeviceScreen::Saved);
    return_to_idle_after(DeviceScreen::Saved, 3000);
    update_storage_status(card_full ? "Card is full\nRecording saved"
                          : completed ? "Recording saved\nReady to play"
                                      : "Recording stopped\nReady to play");
    // The number of the first part is the recording's number: it lets the phone recognise this
    // recording exactly once, however many parts it has.
    char saved_status[64];
    snprintf(saved_status, sizeof(saved_status), "%s: ready to play #%lu",
        completed ? "Recording saved" : "Recording stopped", static_cast<unsigned long>(first_id));
    report_audio_status(saved_status);
    if (card_full) report_audio_status("Card is full: the recording was stopped");  // not "Recording stopped…": the app reads that as a new note
    finish_audio_task();
}

// Plays a mono 16-bit chunk through the stereo codec. `stereo` needs room for twice `bytes`.
bool play_mono_chunk(const uint8_t *chunk, size_t bytes, uint8_t *stereo_buffer) {
    auto *mono = reinterpret_cast<const int16_t *>(chunk);
    auto *stereo = reinterpret_cast<int16_t *>(stereo_buffer);
    const size_t samples = bytes / sizeof(int16_t);
    for (size_t index = 0; index < samples; ++index) {
        stereo[index * 2] = mono[index];
        stereo[index * 2 + 1] = mono[index];
    }
    return Codec_PlaybackData(stereo_buffer, samples * kCodecCaptureChannels * sizeof(int16_t)) == ESP_OK;
}

// Plays one note, in whichever form it is stored. False if it could not be played at all.
bool play_note(uint32_t id) {
    circuit_notes::Note note = {};
    char path[48] = {};
    const bool found = id != 0 && circuit_notes::describe(id, &note);
    if (found) circuit_notes::note_path(note, path, sizeof(path));
    auto *reader = (found && note.encrypted) ? new (std::nothrow) circuit_secure::Reader() : nullptr;
    FILE *plain = nullptr;
    WavHeader header{};
    bool ready = audio_ready && found;
    if (ready && note.encrypted) {
        ready = reader != nullptr && reader->open(path) && reader->channels() == 1 && reader->bits() == 16;
    } else if (ready) {
        plain = fopen(path, "rb");
        ready = plain != nullptr && fread(&header, sizeof(header), 1, plain) == 1 &&
                memcmp(header.riff, "RIFF", 4) == 0 && memcmp(header.wave, "WAVE", 4) == 0 && header.channels == 1;
    }
    uint8_t *buffer = ready ? static_cast<uint8_t *>(heap_caps_malloc(kAudioBufferBytes, MALLOC_CAP_SPIRAM)) : nullptr;
    uint8_t *stereo_buffer = ready ? static_cast<uint8_t *>(heap_caps_malloc(kAudioBufferBytes * 2, MALLOC_CAP_SPIRAM)) : nullptr;
    if (!ready || buffer == nullptr || stereo_buffer == nullptr) {
        if (buffer != nullptr) heap_caps_free(buffer);
        if (stereo_buffer != nullptr) heap_caps_free(stereo_buffer);
        if (plain != nullptr) fclose(plain);
        delete reader;
        const bool memory = ready;  // everything was fine except the buffers
        update_storage_status(memory ? "Playback failed\nNot enough memory" : "No recording found\nRecord audio first");
        report_audio_status(memory ? "Playback failed: memory unavailable" : "Playback failed: no recording found");
        return false;
    }

    bool wrote_audio = false;
    bool output_failed = false;
    if (reader != nullptr) {
        // read() returns 0 at the end of the note, or at a chunk that does not authenticate
        // (damaged, or a recording cut short while it was being written): playback just stops.
        size_t bytes = 0;
        while (!playback_stop_requested.load() && (bytes = reader->read(buffer)) > 0) {
            if (!play_mono_chunk(buffer, bytes, stereo_buffer)) { output_failed = true; break; }
            wrote_audio = true;
            playback_audio_ms.fetch_add(static_cast<uint32_t>(bytes * 1000 / (kAudioSampleRate * 2)));
        }
    } else {
        size_t bytes = 0;
        while (!playback_stop_requested.load() && (bytes = fread(buffer, 1, kAudioBufferBytes, plain)) > 0) {
            if (!play_mono_chunk(buffer, bytes, stereo_buffer)) { output_failed = true; break; }
            wrote_audio = true;
            playback_audio_ms.fetch_add(static_cast<uint32_t>(bytes * 1000 / (kAudioSampleRate * 2)));
        }
    }
    heap_caps_free(buffer);
    heap_caps_free(stereo_buffer);
    if (plain != nullptr) fclose(plain);
    delete reader;
    if (!playback_stop_requested.load() && (!wrote_audio || output_failed)) {
        update_storage_status("Playback failed\nCould not play audio");
        report_audio_status(output_failed ? "Playback failed: speaker output error" : "Playback failed: recording could not be read");
        return false;
    }
    return true;
}

// Plays the newest recording. One made of parts plays all of them, in order.
void play_audio_task(void *) {
    const uint32_t last = circuit_notes::newest_id();
    uint32_t first = last;
    circuit_notes::Group group;
    if (last != 0 && circuit_notes::read_group(last, &group) && group.first != 0 && group.first <= last) first = group.first;
    show_device_screen(DeviceScreen::Playback);
    update_storage_status("Playing on Circuit");
    report_audio_status("Playing latest recording");
    bool played = false;
    bool failed = false;
    if (last == 0) play_note(0);  // reports that there is nothing to play
    for (uint32_t id = first; id != 0 && id <= last && !playback_stop_requested.load(); ++id) {
        circuit_notes::Note note;
        if (!circuit_notes::describe(id, &note)) {
            if (id == last && !played) play_note(id);  // reports that there is nothing to play
            continue;
        }
        if (!play_note(id)) { failed = true; break; }
        played = true;
    }
    playback_active = false;
    if (playback_stop_requested.load()) {
        update_storage_status("Playback stopped");
        report_audio_status("Playback stopped");
    } else if (played && !failed) {
        update_storage_status("Playback complete");
        report_audio_status("Playback complete");
    }
    if (Lvgl_lock(-1)) {
        lv_obj_add_flag(recording_timer_label, LV_OBJ_FLAG_HIDDEN);
        Lvgl_unlock();
    }
    return_to_idle_after(DeviceScreen::Playback, 2500);
    finish_audio_task();
}

void start_recording(char *command) {
    uint32_t seconds = 5;
    char *duration = strchr(command, '\n');
    if (duration != nullptr) {
        seconds = strtoul(duration + 1, nullptr, 10);
    }
    if (seconds == 0 || seconds > kMaxRecordingSeconds) {
        char limit_text[48];
        snprintf(limit_text, sizeof(limit_text), "Recording length: 1–%lu sec", static_cast<unsigned long>(kMaxRecordingSeconds));
        update_storage_status(limit_text);
        snprintf(limit_text, sizeof(limit_text), "Recording failed: choose 1–%lu seconds", static_cast<unsigned long>(kMaxRecordingSeconds));
        report_audio_status(limit_text);
        return;
    }
    // Recording and syncing are never done together: the card, the radio and the memory are
    // shared, and a recording must not lose a word to a sync.
    if (circuit_sync::is_open() || audio_sync_task_handle != nullptr || !free_audio_from_playback()) {
        show_busy_notice();
        return;
    }
    if (!crypto_self_test_ok) {
        update_storage_status("Encryption check failed\nNot recording");
        report_audio_status("Recording failed: encryption self-test failed");
        return;
    }
    if (!note_key_ready) {
        update_storage_status("Pair Circuit with\nthe app first");
        report_audio_status("Recording failed: pair Circuit with the app first");
        return;
    }
    if (!claim_audio()) {  // another request took the microphone a moment ago
        show_busy_notice();
        return;
    }
    if (circuit_sync::is_open()) {  // a sync opened between the check above and the claim
        audio_busy = false;
        show_busy_notice();
        return;
    }
    recording_active = true;
    recording_paused = false;
    recording_stop_requested = false;
    xTaskCreate(record_audio_task, "audio_record", 6144,
                reinterpret_cast<void *>(static_cast<uintptr_t>(seconds)), 5, nullptr);
}

void stop_recording() {
    if (!recording_active) {
        report_audio_status("No recording is in progress");
        return;
    }
    recording_stop_requested = true;
    report_audio_status("Stopping recording…");
}

// Pauses a recording, or carries it on. The note stays open: it is one note, with the pause
// left out of it.
void toggle_pause_recording() {
    if (!recording_active || recording_stop_requested) return;
    recording_paused = !recording_paused;
    ESP_LOGI(kTag, "Recording %s", recording_paused ? "paused" : "resumed");
    report_audio_status(recording_paused ? "Recording paused" : "Recording resumed");
}

// Slow BLE fallback, used only for a force sync with no Wi-Fi sync available.
// Sends the oldest unsynced note and marks it synced once every packet has been
// acknowledged by the phone's BLE stack.
void audio_sync_task(void *) {
    circuit_notes::Note oldest[1];
    const size_t waiting = circuit_notes::list_unsynced(oldest, 1);
    char latest[48] = {};
    if (waiting > 0) circuit_notes::note_path(oldest[0], latest, sizeof(latest));
    FILE *file = waiting > 0 ? fopen(latest, "rb") : nullptr;
    if (file == nullptr || connection_id == UINT16_MAX || relay_handle == 0) {
        if (file != nullptr) fclose(file);
        update_storage_status("Sync failed\nConnect Short-Circuit");
        report_audio_status("Sync failed: phone is not connected");
        finish_audio_task();
        audio_sync_task_handle = nullptr;
        return;
    }
    fseek(file, 0, SEEK_END);
    const long length = ftell(file);
    rewind(file);
    if (length <= 0) {
        fclose(file);
        update_storage_status("Sync failed\nNo recording found");
        report_audio_status("Sync failed: no recording found");
        finish_audio_task();
        audio_sync_task_handle = nullptr;
        return;
    }

    show_device_screen(DeviceScreen::Syncing);
    char started[kMaxTextBytes + 1];
    snprintf(started, sizeof(started), "Sync started\n%ld bytes", length);
    update_storage_status("Syncing audio\n0%");
    report_audio_status(started);

    uint8_t buffer[kAudioPacketBytes];
    long sent = 0;
    int last_progress_bucket = -1;
    bool failed = false;
    while (!failed) {
        const size_t bytes = fread(buffer, 1, sizeof(buffer), file);
        if (bytes == 0) break;
        if (send_audio_data(buffer, bytes) != ESP_OK) {
            failed = true;
            break;
        }
        sent += static_cast<long>(bytes);
        const int percent = static_cast<int>((sent * 100) / length);
        if (percent / 10 != last_progress_bucket) {
            char progress[64];
            snprintf(progress, sizeof(progress), "Syncing audio\n%d%%", percent);
            update_storage_status(progress);
            if (Lvgl_lock(-1)) {
                char percent_text[8];
                snprintf(percent_text, sizeof(percent_text), "%d%%", percent);
                lv_label_set_text(sync_progress_label, percent_text);
                Lvgl_unlock();
            }
            snprintf(progress, sizeof(progress), "Sync in progress: %d%%", percent);
            report_audio_status(progress);
            last_progress_bucket = percent / 10;
        }
        // ATT confirmation means the packet reached the phone's BLE stack,
        // not necessarily that Android has finished dispatching the callback
        // to the app. Give that callback time to drain before sending the
        // next packet.
        vTaskDelay(pdMS_TO_TICKS(30));
    }
    fclose(file);
    if (failed || sent != length) {
        if (Lvgl_lock(-1)) {
            lv_label_set_text(sync_progress_label, "ERR");
            Lvgl_unlock();
        }
        return_to_idle_after(DeviceScreen::Syncing, 3000);
        update_storage_status("Sync failed\nTry again in app");
        report_audio_status("Sync failed: connection interrupted");
    } else {
        if (Lvgl_lock(-1)) {
            lv_label_set_text(sync_progress_label, "100%");
            Lvgl_unlock();
        }
        return_to_idle_after(DeviceScreen::Syncing, 3000);
        circuit_notes::mark_synced(oldest[0].id);
        update_storage_status("Sync complete\nReady on phone");
        report_audio_status("Sync complete: ready on phone");
    }
    finish_audio_task();
    audio_sync_task_handle = nullptr;
}

// ---- Wi-Fi state, status icons and app feedback ---------------------------

const char *wifi_reason_text(uint8_t reason) {
    switch (reason) {
    case WIFI_REASON_NO_AP_FOUND:
    case WIFI_REASON_NO_AP_FOUND_IN_RSSI_THRESHOLD:
    case WIFI_REASON_NO_AP_FOUND_W_COMPATIBLE_SECURITY:
    case WIFI_REASON_NO_AP_FOUND_IN_AUTHMODE_THRESHOLD:
        return "Network not found";
    case WIFI_REASON_AUTH_FAIL:
    case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_MIC_FAILURE:
    case WIFI_REASON_AUTH_EXPIRE:
        return "Wrong password";
    case WIFI_REASON_ASSOC_FAIL:
    case WIFI_REASON_ASSOC_TOOMANY:
        return "Router refused the connection";
    default:
        return "Could not connect";
    }
}

void send_wifi_status() {
    static const char *const names[] = {"none", "connecting", "connected", "failed"};
    char message[kMaxTextBytes + 1];
    // The Wi-Fi MAC address goes last as "mac=..." so older apps, which read everything after the
    // third line as the detail, just show it there and newer ones pick it out.
    uint8_t mac[6] = {};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(message, sizeof(message), "@wifi-status\n%s\n%s\n%s\nmac=%02X:%02X:%02X:%02X:%02X:%02X",
        names[static_cast<int>(wifi_ui)], wifi_ssid, wifi_detail, mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    send_relay_request(message);
}

// Tells the app how many recordings are waiting (a long one made of parts counts once) and why
// the board last restarted, so the app can show a sync that is stuck, and a crash, instead of
// guessing.
void send_sync_status() {
    char message[kMaxTextBytes + 1];
    // The first three lines are what the app has always read; the rest is board health,
    // forwarded to the app's diagnostics (counts and sizes only).
    snprintf(message, sizeof(message),
        "@sync-status\nwaiting=%u\nreset=%d\nuptime=%lld\nfree_min=%u\nstack_min=%u\nstops=%u",
        static_cast<unsigned>(circuit_notes::count_unsynced_recordings()), boot_reset_reason,
        static_cast<long long>(circuit_sync::now_ms() / 1000),
        static_cast<unsigned>(heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL)),
        static_cast<unsigned>(text_stack_min_bytes == UINT32_MAX ? 0 : text_stack_min_bytes),
        static_cast<unsigned>(circuit_sync::download_stops));
    send_relay_request(message);
    // A separate short snapshot keeps both packets within the 160-byte BLE limit.
    snprintf(message, sizeof(message), "@sync-status\nplayback=%s\nplayback_ms=%lu\nplayback_stop=1",
        playback_active.load() ? "playing" : "idle",
        static_cast<unsigned long>(playback_active.load() ? playback_audio_ms.load() : 0));
    send_relay_request(message);
}

void set_wifi_ui(WifiUi state, const char *detail = "") {
    wifi_ui = state;
    snprintf(wifi_detail, sizeof(wifi_detail), "%s", detail);
    if (state == WifiUi::Failed) wifi_failed_at_ms = circuit_sync::now_ms();
    send_wifi_status();
}

// Redraws the header icons when what they show has changed. Icons only appear
// for things that are available: Wi-Fi once configured (animated while it is
// connecting, crossed out if it failed), the phone while bonded, the SD card.
void refresh_status_icons() {
    if (boot_splash) return;
    static const lv_image_dsc_t *const connecting[] = {
        &circuit_icon_wifi_zero, &circuit_icon_wifi_low, &circuit_icon_wifi_high, &circuit_icon_wifi};
    static const lv_image_dsc_t *shown_wifi = nullptr;
    static int shown_state = -1;
    const lv_image_dsc_t *wifi_src = nullptr;
    switch (wifi_ui) {
    case WifiUi::Connected: wifi_src = &circuit_icon_wifi; break;
    case WifiUi::Failed: wifi_src = &circuit_icon_wifi_off; break;
    case WifiUi::Connecting: wifi_src = connecting[status_icon_frame % 4]; break;
    default: break;
    }
    const bool phone = ble_encrypted;
    const bool storage = sd_card != nullptr;
    const int state = (phone ? 1 : 0) | (storage ? 2 : 0);
    if (wifi_src == shown_wifi && state == shown_state) return;
    if (!Lvgl_lock(-1)) return;
    shown_wifi = wifi_src;
    shown_state = state;
    int x_right = 198;
    const auto place = [&x_right](lv_obj_t *object, const lv_image_dsc_t *source, int y) {
        if (source == nullptr) {
            lv_obj_add_flag(object, LV_OBJ_FLAG_HIDDEN);
            return;
        }
        lv_img_set_src(object, source);
        lv_obj_set_pos(object, x_right - source->header.w, y);
        lv_obj_clear_flag(object, LV_OBJ_FLAG_HIDDEN);
        x_right -= source->header.w + 3;
    };
    place(icon_storage_obj, storage ? &circuit_icon_hard_drive : nullptr, 5);
    place(icon_phone_obj, phone ? &circuit_icon_phone : nullptr, 5);
    place(icon_wifi_obj, wifi_src, 3);
    Lvgl_unlock();
}

void sync_ui_tick();

void status_icon_task(void *) {
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(900));
        ++status_icon_frame;
        refresh_status_icons();
        sync_ui_tick();
    }
}

// ---- Wi-Fi sync sessions -------------------------------------------------

// Called from the HTTPS server task for every chunk. It must never touch the
// display: redrawing the e-paper takes a second or more, and waiting for it
// stalls the download. It only records the figure; sync_ui_tick() draws it.
volatile int32_t sync_ui_percent = -1;
int32_t sync_ui_shown = -1;

void wifi_sync_progress(uint32_t percent) { sync_ui_percent = static_cast<int32_t>(percent); }

// Runs in the status icon task, at most once per tick.
void sync_ui_tick() {
    const int32_t percent = sync_ui_percent;
    if (percent < 0 || percent == sync_ui_shown) return;
    // Never take the screen from a recording.
    if (recording_active || active_screen == DeviceScreen::Recording) return;
    if (active_screen != DeviceScreen::Syncing) show_device_screen(DeviceScreen::Syncing);
    if (Lvgl_lock(-1)) {
        char text[16];
        snprintf(text, sizeof(text), "%d%%", static_cast<int>(percent));
        lv_label_set_text(sync_progress_label, text);
        Lvgl_unlock();
    }
    sync_ui_shown = percent;
}

bool can_offer_wifi_sync() {
    char ip[16];
    return ble_encrypted && connection_id != UINT16_MAX && circuit_sync::wifi_ip(ip, sizeof(ip)) &&
           !circuit_sync::is_open() && !circuit_sync::locked_out() && !audio_busy;
}

// Opens a session and hands the phone what it needs over the bonded BLE link.
bool offer_wifi_sync(uint32_t only_recording = 0) {
    char ip[16];
    uint16_t port = 0;
    char token[33];
    const char *fingerprint = nullptr;
    uint32_t count = 0, bytes = 0;
    if (!can_offer_wifi_sync() || !circuit_sync::wifi_ip(ip, sizeof(ip))) return false;
    circuit_sync::state.on_progress = wifi_sync_progress;
    sync_ui_percent = -1;
    sync_ui_shown = -1;
    if (!circuit_sync::open_session(&port, token, sizeof(token), &fingerprint, &count, &bytes, only_recording)) return false;
    if (audio_busy) {  // a recording started while the session was opening: it wins
        circuit_sync::close_session();
        return false;
    }
    char offer[kMaxTextBytes + 40];
    snprintf(offer, sizeof(offer), "@sync-offer\n%s\n%u\n%s\n%s\n%lu\n%lu", ip, static_cast<unsigned>(port), token,
        fingerprint, static_cast<unsigned long>(count), static_cast<unsigned long>(bytes));
    snprintf(last_offer, sizeof(last_offer), "%s", offer);
    last_offer_sent_ms = circuit_sync::now_ms();
    send_relay_request(offer);
    ESP_LOGI(kTag, "Wi-Fi sync offered: %lu notes, %lu bytes", static_cast<unsigned long>(count),
        static_cast<unsigned long>(bytes));
    return true;
}

// Shows the sync screen briefly with `text`, then returns to idle. Used so a
// button hold always gets a visible answer.
void flash_sync_result(const char *text) {
    show_device_screen(DeviceScreen::Syncing);
    if (Lvgl_lock(-1)) {
        lv_label_set_text(sync_progress_label, text);
        Lvgl_unlock();
    }
    return_to_idle_after(DeviceScreen::Syncing, 2500);
}

// Swaps the sync figure for the "cannot record" icon, or back.
void show_busy_icon(bool on) {
    if (!Lvgl_lock(-1)) return;
    if (on) {
        lv_obj_add_flag(sync_progress_label, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(busy_icon_obj, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(busy_icon_obj, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(sync_progress_label, LV_OBJ_FLAG_HIDDEN);
    }
    Lvgl_unlock();
}

// Puts the sync figure back after a short notice, if the sync screen is still up.
void restore_sync_label_task(void *) {
    vTaskDelay(pdMS_TO_TICKS(2500));
    if (active_screen == DeviceScreen::Syncing) show_busy_icon(false);
    vTaskDelete(nullptr);
}

// The key (or the app) asked to record while something else has the microphone, such as a
// sync. Say so on the screen, with an icon, and to the phone: a press must always get an
// answer, never silence.
void show_busy_notice() {
    const bool syncing = audio_sync_task_handle != nullptr || circuit_sync::is_open();
    update_storage_status(syncing ? "Sync is running\nRecord when it ends" : "Audio is busy\nPlease wait");
    report_audio_status(syncing ? "Can't record: a sync is running, try again when it ends" : "Audio is busy");
    if (recording_active) return;  // the recording screen is already up
    if (active_screen == DeviceScreen::Syncing) {
        show_busy_icon(true);
        xTaskCreate(restore_sync_label_task, "busy_notice", 3072, nullptr, 2, nullptr);
        return;
    }
    show_device_screen(DeviceScreen::Syncing);  // the sync screen, with the icon in place of the figure
    show_busy_icon(true);
    return_to_idle_after(DeviceScreen::Syncing, 2500);
}

void end_wifi_sync() {
    const uint32_t served = circuit_sync::state.served_bytes;
    const int64_t started = circuit_sync::state.session_started_ms;
    const int64_t first = circuit_sync::state.first_request_ms;
    const int64_t took = circuit_sync::now_ms() - (first ? first : started);
    ESP_LOGW(kTag, "SYNCSTAT served=%lu bytes, session %lld ms, first request after %lld ms, transfer %lld ms (%lld KB/s)",
        static_cast<unsigned long>(served), static_cast<long long>(circuit_sync::now_ms() - started),
        static_cast<long long>(first ? first - started : -1), static_cast<long long>(took),
        static_cast<long long>(took > 0 ? served * 1000LL / took / 1024 : 0));
    ESP_LOGW(kTag, "Memory after sync: internal free %u, lowest ever %u, largest block %u",
        static_cast<unsigned>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL)),
        static_cast<unsigned>(heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL)),
        static_cast<unsigned>(heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL)));
    const bool session_done = circuit_sync::waiting_in_session() == 0;  // before the session forgets which recording
    circuit_sync::close_session();
    sync_ui_percent = -1;
    if (served == 0) {  // the phone never connected: back off, and say so if the screen is showing sync
        if (active_screen == DeviceScreen::Syncing) flash_sync_result("ERR");
        return;
    }
    const bool complete = session_done;
    if (Lvgl_lock(-1)) {
        lv_label_set_text(sync_progress_label, complete ? "100%" : "ERR");
        Lvgl_unlock();
    }
    return_to_idle_after(DeviceScreen::Syncing, 3000);
    report_audio_status(complete ? "Sync complete: notes saved on phone" : "Sync interrupted: will retry");
}

// Looks after a sync someone asked for, and closes sessions that finished, stalled or were
// abused. It never starts one.
void sync_supervisor_task(void *) {
    // Create (or load) the sync certificate now so a failure shows up at boot.
    ESP_LOGI(kTag, "Sync identity %s", circuit_sync::ensure_identity() ? "ready" : "FAILED");
    while (true) {
        vTaskDelay(kSyncSupervisorInterval);
        // After giving up, try again now and then (sooner if it was not a password problem).
        if (wifi_ui == WifiUi::Failed && wifi_ssid[0] != '\0' &&
            circuit_sync::now_ms() - wifi_failed_at_ms > (wifi_auth_failure ? 300000 : 60000)) {
            wifi_retries = 0;
            set_wifi_ui(WifiUi::Connecting);
            esp_wifi_connect();
        }
        if (circuit_sync::is_open()) {
            const bool all_synced = circuit_sync::state.acked > 0 && circuit_sync::waiting_in_session() == 0;
            if (all_synced || circuit_sync::expired() || connection_id == UINT16_MAX) {
                end_wifi_sync();
            } else if (circuit_sync::state.client_ip == 0 && ble_encrypted &&
                       circuit_sync::now_ms() - last_offer_sent_ms > kOfferResendMs) {
                // An offer sent before the phone had subscribed to notifications is lost,
                // so keep offering until the phone connects.
                last_offer_sent_ms = circuit_sync::now_ms();
                send_relay_request(last_offer);
                ESP_LOGI(kTag, "Wi-Fi sync offer re-sent (phone has not connected yet)");
            }
            continue;
        }
        // No sync starts by itself: one only starts when someone asks for it (the key held for
        // 2 s, or the app), so it never lands in the middle of a recording or a bad moment.
    }
}

// `forced` is the device button: it falls back to BLE when Wi-Fi sync is not
// possible. The app can only ask for Wi-Fi sync.
// `only_recording` (the app's "sync this note") limits the sync to that recording; 0 syncs everything.
void start_audio_sync(bool forced, uint32_t only_recording = 0) {
    if (!free_audio_from_playback()) {  // playing a note gives way; a recording does not
        report_audio_status("Audio is busy");
        return;
    }
    ESP_LOGI(kTag, "Sync requested (%s%s): %u file(s) waiting", forced ? "button" : "app",
        only_recording != 0 ? ", one recording" : "",
        static_cast<unsigned>(circuit_notes::count_unsynced_of(only_recording)));
    if (circuit_notes::count_unsynced_of(only_recording) == 0) {
        update_storage_status("Nothing to sync");
        if (only_recording != 0) {
            // Not "no new notes": that tells the app nothing at all is waiting.
            char text[48];
            snprintf(text, sizeof(text), "Sync: nothing waiting for #%lu", static_cast<unsigned long>(only_recording));
            report_audio_status(text);
        } else {
            report_audio_status("Sync: no new notes");
        }
        if (forced) flash_sync_result("OK");  // everything is already on the phone
        return;
    }
    if (circuit_sync::is_open()) {
        report_audio_status("Sync already in progress");
        return;
    }
    if (offer_wifi_sync(only_recording)) {
        if (forced) {  // show progress right away; the phone connects within a second or two
            show_device_screen(DeviceScreen::Syncing);
            if (Lvgl_lock(-1)) {
                lv_label_set_text(sync_progress_label, "0%");
                Lvgl_unlock();
            }
        }
        return;
    }
    if (!forced) {
        update_storage_status("Sync needs Wi-Fi\nCircuit and phone");
        report_audio_status("Sync needs Wi-Fi: connect Circuit and your phone to the same network");
        return;
    }
    if (!claim_audio()) {
        report_audio_status("Audio is busy");
        return;
    }
    xTaskCreate(audio_sync_task, "audio_sync", 6144, nullptr, 4, &audio_sync_task_handle);
}

void force_sync_task(void *) {
    update_storage_status("Force sync requested\nStarting sync…");
    report_audio_status("Force sync requested");
    start_audio_sync(true);
    vTaskDelete(nullptr);
}

// The upper side button (BOOT, GPIO0) is the only key, and it does different things by state:
//   idle       tap: start a recording      hold 2 s: force a sync (Bluetooth if there is no Wi-Fi)
//   recording  tap: stop and save          hold 1 s: pause, or carry on
// The lower button is wired to power, so holding it switches the board off.
void record_button_task(void *) {
    // GPIO0 is active-low. Waiting for a released state avoids treating a
    // button held during boot as an unintended request.
    bool was_pressed = gpio_get_level(kRecordButtonPin) == 0;
    TickType_t pressed_at = 0;
    bool hold_handled = false;
    while (true) {
        const bool is_pressed = gpio_get_level(kRecordButtonPin) == 0;
        if (is_pressed && !was_pressed) {
            vTaskDelay(kButtonDebounceDelay);
            if (gpio_get_level(kRecordButtonPin) == 0) {
                pressed_at = xTaskGetTickCount();
                hold_handled = false;
            } else {
                was_pressed = false;
                continue;
            }
        }
        const TickType_t hold_needed = recording_active ? kPauseHoldTime : kForceSyncHoldTime;
        if (is_pressed && !hold_handled && xTaskGetTickCount() - pressed_at >= hold_needed) {
            hold_handled = true;
            if (recording_active) {
                ESP_LOGI(kTag, "BOOT held: pause or resume");
                toggle_pause_recording();
            } else {
                ESP_LOGI(kTag, "BOOT held: force sync");
                // Starting a sync is heavy (it lists the card and opens a session), far more than
                // this key task's small stack allows: it runs in a task of its own.
                if (xTaskCreate(force_sync_task, "force_sync", 6144, nullptr, 4, nullptr) != pdPASS) {
                    report_audio_status("Could not start the sync");
                }
            }
        }
        if (!is_pressed && was_pressed && !hold_handled) {  // released: it was a tap
            if (recording_active) {
                stop_recording();
            } else {
                // Records until stopped or the cap is hit.
                char command[32];
                snprintf(command, sizeof(command), "@audio-record\n%lu", static_cast<unsigned long>(kMaxRecordingSeconds));
                start_recording(command);
            }
        }
        was_pressed = is_pressed;
        vTaskDelay(kButtonPollInterval);
    }
}

void init_record_button() {
    gpio_config_t config = {
        .pin_bit_mask = 1ULL << kRecordButtonPin,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&config));
    xTaskCreate(record_button_task, "record_button", 3072, nullptr, 3, nullptr);
}

void start_playback() {
    if (audio_busy) {
        update_storage_status("Audio is busy\nPlease wait");
        report_audio_status("Audio is busy");
        return;
    }
    if (!claim_audio()) {
        report_audio_status("Audio is busy");
        return;
    }
    playback_stop_requested = false;
    playback_audio_ms = 0;
    playback_active = true;
    if (xTaskCreate(play_audio_task, "audio_play", 6144, nullptr, 5, nullptr) != pdPASS) {
        playback_active = false;
        audio_busy = false;
        report_audio_status("Playback failed: could not start playback");
    }
}

void on_ping_success(esp_ping_handle_t, void *) {
    wifi_internet_online = true;
    update_connection_status("Wi-Fi: connected\nInternet: online\nPhone relay: unavailable");
}

void on_ping_end(esp_ping_handle_t handle, void *) {
    uint32_t replies = 0;
    uint32_t replies_size = sizeof(replies);
    esp_ping_get_profile(handle, ESP_PING_PROF_REPLY, &replies, replies_size);
    if (replies == 0) {
        wifi_internet_online = false;
        update_connection_status("Wi-Fi: connected\nInternet: offline\nPhone relay: unavailable");
    }
    esp_ping_delete_session(handle);
}

void check_wifi_internet() {
    esp_ping_config_t config = ESP_PING_DEFAULT_CONFIG();
    config.count = 1;
    config.timeout_ms = 3000;
    ipaddr_aton("8.8.8.8", &config.target_addr);
    esp_ping_callbacks_t callbacks = {
        .cb_args = nullptr,
        .on_ping_success = on_ping_success,
        .on_ping_timeout = nullptr,
        .on_ping_end = on_ping_end,
    };
    esp_ping_handle_t ping = nullptr;
    if (esp_ping_new_session(&config, &callbacks, &ping) != ESP_OK || esp_ping_start(ping) != ESP_OK) {
        update_connection_status("Wi-Fi: connected\nInternet: offline\nPhone relay: unavailable");
    }
}

// Keeps the date and clock current from SNTP over Wi-Fi whenever the phone has
// not sent a fresh @home update. Note counts still come from the phone.
void on_sntp_sync(timeval *) {
    // One sync is enough; the system clock keeps time from here.
    clock_set = true;
    esp_sntp_stop();
}

void local_clock_task(void *) {
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(10000));
        const time_t now = time(nullptr);
        if (!clock_set || now < kMinValidEpoch) continue;
        if (!Lvgl_lock(-1)) continue;
        show_local_time(now);
        Lvgl_unlock();
    }
}

void start_sntp() {
    if (sntp_started || clock_set) return;
    sntp_started = true;
    esp_sntp_setoperatingmode(ESP_SNTP_OPMODE_POLL);
    esp_sntp_setservername(0, "pool.ntp.org");
    sntp_set_time_sync_notification_cb(on_sntp_sync);
    esp_sntp_init();
}

void wifi_event_handler(void *, esp_event_base_t event_base, int32_t event_id, void *event_data) {
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_CONNECTED) {
        wifi_connected = true;
        wifi_internet_online = false;
        update_connection_status("Wi-Fi: connected\nInternet: checking…\nPhone relay: unavailable");
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        const uint8_t reason = static_cast<wifi_event_sta_disconnected_t *>(event_data)->reason;
        wifi_connected = false;
        wifi_internet_online = false;
        update_connection_status("Wi-Fi: offline\nInternet: offline\nPhone relay: unavailable");
        if (wifi_manual_disconnect) {  // we caused this one while switching networks
            wifi_manual_disconnect = false;
            return;
        }
        if (wifi_ui == WifiUi::None) return;
        if (wifi_retries < kWifiMaxRetries) {
            ++wifi_retries;
            set_wifi_ui(WifiUi::Connecting);
            esp_wifi_connect();
        } else {
            wifi_auth_failure = reason == WIFI_REASON_AUTH_FAIL || reason == WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT ||
                                reason == WIFI_REASON_HANDSHAKE_TIMEOUT;
            set_wifi_ui(WifiUi::Failed, wifi_reason_text(reason));
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        const auto *got = static_cast<ip_event_got_ip_t *>(event_data);
        char ip[16];
        snprintf(ip, sizeof(ip), IPSTR, IP2STR(&got->ip_info.ip));
        wifi_retries = 0;
        wifi_auth_failure = false;
        set_wifi_ui(WifiUi::Connected, ip);
        check_wifi_internet();
        start_sntp();
    }
}

bool parse_wifi_command(char *value, wifi_config_t *config) {
    if (strncmp(value, kWifiCommandPrefix, strlen(kWifiCommandPrefix)) != 0) {
        return false;
    }

    char *ssid = value + strlen(kWifiCommandPrefix);
    char *password = strchr(ssid, '\n');
    if (password == nullptr) {
        return false;
    }
    *password++ = '\0';

    const size_t ssid_length = strlen(ssid);
    const size_t password_length = strlen(password);
    if (ssid_length == 0 || ssid_length > sizeof(config->sta.ssid) - 1 ||
        password_length > sizeof(config->sta.password) - 1) {
        return false;
    }

    memset(config, 0, sizeof(*config));
    memcpy(config->sta.ssid, ssid, ssid_length);
    memcpy(config->sta.password, password, password_length);
    config->sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
    config->sta.sort_method = WIFI_CONNECT_AP_BY_SIGNAL;
    config->sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    return true;
}

void provision_wifi(char *value) {
    wifi_config_t config = {};
    if (!parse_wifi_command(value, &config)) {
        update_connection_status("Wi-Fi setup failed\nCheck SSID/password");
        wifi_ssid[0] = '\0';
        set_wifi_ui(WifiUi::Failed, "Invalid network name or password");
        return;
    }
    // Switching networks makes the old link report a disconnect we should ignore.
    wifi_manual_disconnect = wifi_connected;
    esp_wifi_disconnect();
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &config));
    snprintf(wifi_ssid, sizeof(wifi_ssid), "%s", reinterpret_cast<const char *>(config.sta.ssid));
    wifi_retries = 0;
    update_connection_status("Wi-Fi: connecting…\nInternet: checking…\nPhone relay: unavailable");
    set_wifi_ui(WifiUi::Connecting);
    ESP_ERROR_CHECK(esp_wifi_connect());
}

void forget_wifi() {
    wifi_manual_disconnect = wifi_connected;
    esp_wifi_disconnect();
    wifi_config_t empty = {};
    esp_wifi_set_config(WIFI_IF_STA, &empty);
    wifi_ssid[0] = '\0';
    wifi_retries = 0;
    set_wifi_ui(WifiUi::None);
    update_connection_status("Wi-Fi: not configured\nInternet: offline\nPhone relay: unavailable");
}

void wifi_scan_task(void *) {
    update_connection_status("Wi-Fi: scanning nearby networks…");
    wifi_scan_config_t config = {};
    if (esp_wifi_scan_start(&config, true) != ESP_OK) {
        send_relay_request("@wifi-list\n");
        vTaskDelete(nullptr);
        return;
    }

    wifi_ap_record_t access_points[10] = {};
    uint16_t count = 10;
    ESP_ERROR_CHECK(esp_wifi_scan_get_ap_records(&count, access_points));
    char response[kMaxTextBytes + 1] = "@wifi-list";
    size_t used = strlen(response);
    for (uint16_t index = 0; index < count; ++index) {
        const char *ssid = reinterpret_cast<const char *>(access_points[index].ssid);
        const size_t length = strlen(ssid);
        if (length == 0 || used + length + 1 > kMaxTextBytes) continue;
        response[used++] = '\n';
        memcpy(response + used, ssid, length);
        used += length;
        response[used] = '\0';
    }
    send_relay_request(response);
    update_connection_status("Wi-Fi: select a network\nInternet: offline\nPhone relay: unavailable");
    vTaskDelete(nullptr);
}

void text_display_task(void *) {
    TextMessage message{};
    while (true) {
        if (xQueueReceive(text_queue, &message, portMAX_DELAY) == pdTRUE) {
            if (strcmp(message.value, kWifiScanCommand) == 0) {
                xTaskCreate(wifi_scan_task, "wifi_scan", 4096, nullptr, 3, nullptr);
            } else if (strncmp(message.value, "@audio-record", 13) == 0) {
                start_recording(message.value);
            } else if (strcmp(message.value, "@audio-stop") == 0) {
                stop_recording();
            } else if (strcmp(message.value, "@audio-play") == 0) {
                start_playback();
            } else if (strcmp(message.value, "@audio-play-stop") == 0) {
                if (playback_active.load()) playback_stop_requested = true;
                else report_audio_status("Playback stopped");
            } else if (strcmp(message.value, "@audio-sync") == 0) {
                start_audio_sync(false);
            } else if (strncmp(message.value, "@audio-sync\n", 12) == 0) {
                // "@audio-sync\n<recording number>": sync just that note (all its parts).
                start_audio_sync(false, static_cast<uint32_t>(strtoul(message.value + 12, nullptr, 10)));
            } else if (strcmp(message.value, "@audio-clear") == 0) {
                if (audio_busy) {
                    report_audio_status("Audio is busy");
                } else {
                    // Notes are kept on the device; cleaning is a separate step.
                    update_storage_status("Notes are kept\nReady to record");
                    report_audio_status("Audio cleared");
                }
            } else if (strcmp(message.value, "@relay-test") == 0) {
                update_connection_status("Wi-Fi: offline\nInternet: checking phone relay…");
                send_relay_request("@relay\nCHECK");
            } else if (strncmp(message.value, "@relay-result\n", 14) == 0) {
                const bool online = strcmp(message.value + 14, "online") == 0;
                update_connection_status(online
                    ? "Wi-Fi: offline\nInternet: phone relay online"
                    : "Wi-Fi: offline\nInternet: phone relay offline");
            } else if (strncmp(message.value, "@note-delete\n", 13) == 0) {
                // The app deleted this note, so remove Circuit's copy as well. Replying
                // even when the note is already gone lets the app stop retrying.
                const unsigned long id = strtoul(message.value + 13, nullptr, 10);
                char result[48];
                if (id == 0) {
                    snprintf(result, sizeof(result), "Note delete refused");
                } else if (audio_busy || recording_active || circuit_sync::is_open()) {
                    snprintf(result, sizeof(result), "Note delete busy #%lu", id);
                } else {
                    const bool removed = circuit_notes::remove_note(static_cast<uint32_t>(id));
                    ESP_LOGI(kTag, "Deleted note %lu from the card: %s", id, removed ? "removed" : "was already gone");
                    snprintf(result, sizeof(result), "Note deleted #%lu", id);
                }
                report_audio_status(result);
            } else if (strcmp(message.value, "@notes-clean") == 0) {
                if (audio_busy || recording_active || circuit_sync::is_open()) {
                    report_audio_status("Cannot clean notes while recording or syncing");
                } else {
                    const size_t removed = circuit_notes::clean_synced();
                    ESP_LOGI(kTag, "Cleaned %u synced note(s)", static_cast<unsigned>(removed));
                    char result[64];
                    snprintf(result, sizeof(result), "Notes cleaned: %u removed from Circuit", static_cast<unsigned>(removed));
                    report_audio_status(result);
                }
            } else if (strncmp(message.value, "@sec-hello\n", 11) == 0) {
                send_note_key_to_phone(message.value);
            } else if (strcmp(message.value, "@wifi-status") == 0) {
                send_wifi_status();
                send_sync_status();
            } else if (strcmp(message.value, "@wifi-forget") == 0) {
                forget_wifi();
            } else if (strncmp(message.value, kHomeStatusCommand, strlen(kHomeStatusCommand)) == 0) {
                update_home_status(message.value);
            } else if (strncmp(message.value, kWifiCommandPrefix, strlen(kWifiCommandPrefix)) == 0) {
                ESP_LOGI(kTag, "Received Wi-Fi configuration");
                provision_wifi(message.value);
            } else {
                ESP_LOGI(kTag, "Displaying BLE text: %s", message.value);
                update_message(message.value);
            }
            // Log each new low of the unused stack, so the margin is known and not guessed.
            static UBaseType_t lowest_spare = UINT32_MAX;
            const UBaseType_t spare = uxTaskGetStackHighWaterMark(nullptr);
            if (spare < lowest_spare) {
                lowest_spare = spare;
                text_stack_min_bytes = static_cast<uint32_t>(spare);
                ESP_LOGW(kTag, "text_display stack: never less than %u bytes spare", static_cast<unsigned>(spare));
            }
        }
    }
}

void gap_event_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param) {
    switch (event) {
    case ESP_GAP_BLE_ADV_DATA_SET_COMPLETE_EVT:
        ESP_ERROR_CHECK(esp_ble_gap_start_advertising(&adv_params));
        break;
    case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
        ESP_LOGI(kTag, "Advertising as %s", kDeviceName);
        break;
    case ESP_GAP_BLE_SEC_REQ_EVT:
        ESP_ERROR_CHECK(esp_ble_gap_security_rsp(param->ble_security.ble_req.bd_addr, true));
        break;
    case ESP_GAP_BLE_PASSKEY_NOTIF_EVT:
        // A phone that has lost its pairing starts a new one: show the code it asks for,
        // even though this board already has a bond stored.
        ESP_LOGI(kTag, "A phone is pairing; showing the code");
        show_pairing_code();
        break;
    case ESP_GAP_BLE_AUTH_CMPL_EVT: {
        const auto &auth = param->ble_security.auth_cmpl;
        const uint8_t *a = auth.bd_addr;
        if (auth.success) {
            // A bonded phone reconnecting also lands here, with key_present set and no
            // pairing code needed; only a real pairing should show the code.
            ESP_LOGI(kTag, "BLE link secured with %02x:..:%02x (address type %d, new keys %s, auth mode 0x%x)",
                a[0], a[5], auth.addr_type, auth.key_present ? "yes" : "no", auth.auth_mode);
            ble_encrypted = true;
            ensure_note_key();
            if (active_screen == DeviceScreen::Pairing) show_device_screen(DeviceScreen::Idle);
        } else {
            ESP_LOGW(kTag, "BLE security failed with %02x:..:%02x (address type %d): reason 0x%x, %d bonded phone(s) stored",
                a[0], a[5], auth.addr_type, auth.fail_reason, esp_ble_get_bond_device_num());
            show_pairing_code();
        }
        break;
    }
    default:
        break;
    }
}

void send_write_response(esp_gatt_if_t gatts_if, esp_ble_gatts_cb_param_t *param) {
    if (param->write.need_rsp) {
        ESP_ERROR_CHECK(esp_ble_gatts_send_response(
            gatts_if, param->write.conn_id, param->write.trans_id, ESP_GATT_OK, nullptr));
    }
}

void send_relay_request(const char *request) {
    if (server_if == ESP_GATT_IF_NONE || relay_handle == 0 || connection_id == UINT16_MAX) return;
    ESP_ERROR_CHECK(esp_ble_gatts_send_indicate(
        server_if, connection_id, relay_handle, strlen(request),
        reinterpret_cast<uint8_t *>(const_cast<char *>(request)), false));
}

esp_err_t send_audio_data(const uint8_t *data, size_t length) {
    if (server_if == ESP_GATT_IF_NONE || relay_handle == 0 || connection_id == UINT16_MAX || length > kAudioPacketBytes) {
        return ESP_ERR_INVALID_STATE;
    }
    uint8_t packet[kAudioPacketBytes + 2] = {0xA5, 0x5A};
    memcpy(packet + 2, data, length);
    // Audio needs flow control. A confirmed indication prevents the BLE stack
    // from filling its transmit queue after the first packet.
    ulTaskNotifyTake(pdTRUE, 0);
    const esp_err_t status = esp_ble_gatts_send_indicate(
        server_if, connection_id, relay_handle, length + 2, packet, true);
    if (status != ESP_OK) return status;
    return ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1500)) > 0 ? ESP_OK : ESP_ERR_TIMEOUT;
}

void gatts_event_handler(esp_gatts_cb_event_t event, esp_gatt_if_t gatts_if,
                         esp_ble_gatts_cb_param_t *param) {
    switch (event) {
    case ESP_GATTS_REG_EVT: {
        server_if = gatts_if;
        esp_gatt_srvc_id_t service_id = {};
        service_id.is_primary = true;
        service_id.id.inst_id = 0;
        service_id.id.uuid.len = ESP_UUID_LEN_16;
        service_id.id.uuid.uuid.uuid16 = kServiceUuid;
        ESP_ERROR_CHECK(esp_ble_gap_set_device_name(kDeviceName));
        ESP_ERROR_CHECK(esp_ble_gap_config_adv_data(&adv_data));
        ESP_ERROR_CHECK(esp_ble_gatts_create_service(gatts_if, &service_id, kServiceHandles));
        break;
    }
    case ESP_GATTS_CREATE_EVT: {
        service_handle = param->create.service_handle;
        esp_bt_uuid_t text_uuid = {.len = ESP_UUID_LEN_16, .uuid = {.uuid16 = kTextUuid}};
        esp_attr_value_t text_value = {
            .attr_max_len = kMaxTextBytes,
            .attr_len = 0,
            .attr_value = nullptr,
        };
        ESP_ERROR_CHECK(esp_ble_gatts_start_service(service_handle));
        ESP_ERROR_CHECK(esp_ble_gatts_add_char(
            service_handle, &text_uuid, ESP_GATT_PERM_WRITE_ENCRYPTED,
            ESP_GATT_CHAR_PROP_BIT_WRITE | ESP_GATT_CHAR_PROP_BIT_WRITE_NR, &text_value, nullptr));
        break;
    }
    case ESP_GATTS_ADD_CHAR_EVT:
        if (param->add_char.char_uuid.uuid.uuid16 == kTextUuid) {
            text_handle = param->add_char.attr_handle;
            esp_bt_uuid_t relay_uuid = {.len = ESP_UUID_LEN_16, .uuid = {.uuid16 = kRelayUuid}};
            esp_attr_value_t relay_value = {.attr_max_len = kMaxTextBytes, .attr_len = 0, .attr_value = nullptr};
            ESP_ERROR_CHECK(esp_ble_gatts_add_char(
                service_handle, &relay_uuid, ESP_GATT_PERM_READ_ENCRYPTED,
                ESP_GATT_CHAR_PROP_BIT_READ | ESP_GATT_CHAR_PROP_BIT_NOTIFY |
                    ESP_GATT_CHAR_PROP_BIT_INDICATE,
                &relay_value, nullptr));
        } else if (param->add_char.char_uuid.uuid.uuid16 == kRelayUuid) {
            relay_handle = param->add_char.attr_handle;
            esp_bt_uuid_t descriptor_uuid = {.len = ESP_UUID_LEN_16, .uuid = {.uuid16 = ESP_GATT_UUID_CHAR_CLIENT_CONFIG}};
            uint8_t descriptor_value[] = {0x00, 0x00};
            esp_attr_value_t descriptor = {
                .attr_max_len = sizeof(descriptor_value),
                .attr_len = sizeof(descriptor_value),
                .attr_value = descriptor_value,
            };
            ESP_ERROR_CHECK(esp_ble_gatts_add_char_descr(
                service_handle, &descriptor_uuid, ESP_GATT_PERM_READ_ENCRYPTED | ESP_GATT_PERM_WRITE_ENCRYPTED, &descriptor, nullptr));
            ESP_LOGI(kTag, "Relay characteristic ready (handle %u)", relay_handle);
        }
        break;
    case ESP_GATTS_WRITE_EVT: {
        if (param->write.handle == text_handle && !param->write.is_prep) {
            TextMessage message{};
            const size_t length = param->write.len < kMaxTextBytes ? param->write.len : kMaxTextBytes;
            memcpy(message.value, param->write.value, length);
            message.value[length] = '\0';
            xQueueSend(text_queue, &message, 0);
        }
        send_write_response(gatts_if, param);
        break;
    }
    case ESP_GATTS_CONNECT_EVT:
        connection_id = param->connect.conn_id;
    {
        const uint8_t *a = param->connect.remote_bda;
        int bonded_count = esp_ble_get_bond_device_num();
        bool known = false;
        if (bonded_count > 0 && bonded_count <= 8) {
            esp_ble_bond_dev_t list[8];
            int n = 8;
            if (esp_ble_get_bond_device_list(&n, list) == ESP_OK) {
                for (int i = 0; i < n; i++) {
                    if (memcmp(list[i].bd_addr, a, ESP_BD_ADDR_LEN) == 0) known = true;
                }
            }
        }
        ESP_LOGI(kTag, "Short-Circuit connected: %02x:..:%02x (address type %d), %d bonded phone(s) stored, this address %s",
            a[0], a[5], param->connect.ble_addr_type, bonded_count, known ? "is one of them" : "is not listed");
        esp_err_t enc = esp_ble_set_encryption(param->connect.remote_bda, ESP_BLE_SEC_ENCRYPT_MITM);
        if (enc != ESP_OK) ESP_LOGW(kTag, "Could not ask for an encrypted link: %s", esp_err_to_name(enc));
        break;
    }
    case ESP_GATTS_DISCONNECT_EVT:
        connection_id = UINT16_MAX;
        ble_encrypted = false;
        show_relay_disconnected();
        ESP_LOGI(kTag, "Client disconnected (reason 0x%x); advertising again", param->disconnect.reason);
        ESP_ERROR_CHECK(esp_ble_gap_start_advertising(&adv_params));
        break;
    case ESP_GATTS_CONF_EVT:
        if (param->conf.handle == relay_handle && audio_sync_task_handle != nullptr) {
            xTaskNotifyGive(audio_sync_task_handle);
        }
        break;
    default:
        break;
    }
}

void start_ble() {
    ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));
    esp_bt_controller_config_t controller_config = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&controller_config));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));
    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());
    ESP_ERROR_CHECK(esp_ble_gatt_set_local_mtu(185));
    ESP_ERROR_CHECK(esp_ble_gap_register_callback(gap_event_handler));
    esp_ble_auth_req_t auth_req = ESP_LE_AUTH_REQ_SC_MITM_BOND;
    esp_ble_io_cap_t io_capability = ESP_IO_CAP_OUT;
    uint8_t key_size = 16;
    uint8_t init_key = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
    uint8_t response_key = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
    uint8_t only_secure_connections = ESP_BLE_ONLY_ACCEPT_SPECIFIED_AUTH_ENABLE;
    ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_AUTHEN_REQ_MODE, &auth_req, sizeof(auth_req)));
    ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_IOCAP_MODE, &io_capability, sizeof(io_capability)));
    ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_MAX_KEY_SIZE, &key_size, sizeof(key_size)));
    ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_ONLY_ACCEPT_SPECIFIED_SEC_AUTH, &only_secure_connections, sizeof(only_secure_connections)));
    ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_SET_STATIC_PASSKEY, &pairing_passkey, sizeof(pairing_passkey)));
    ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_SET_INIT_KEY, &init_key, sizeof(init_key)));
    ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_SET_RSP_KEY, &response_key, sizeof(response_key)));
    ESP_ERROR_CHECK(esp_ble_gatts_register_callback(gatts_event_handler));
    ESP_ERROR_CHECK(esp_ble_gatts_app_register(0));
}

void start_wifi() {
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(esp_netif_create_default_wifi_sta() != nullptr ? ESP_OK : ESP_FAIL);
    wifi_init_config_t init_config = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init_config));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, nullptr));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, nullptr));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_FLASH));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());

    wifi_config_t saved_config = {};
    ESP_ERROR_CHECK(esp_wifi_get_config(WIFI_IF_STA, &saved_config));
    if (saved_config.sta.ssid[0] != '\0') {
        snprintf(wifi_ssid, sizeof(wifi_ssid), "%s", reinterpret_cast<const char *>(saved_config.sta.ssid));
        update_connection_status("Wi-Fi: reconnecting…\nInternet: checking…\nPhone relay: unavailable");
        set_wifi_ui(WifiUi::Connecting);
        ESP_ERROR_CHECK(esp_wifi_connect());
    } else {
        update_connection_status("Wi-Fi: not configured\nInternet: offline\nPhone relay: unavailable");
    }
}

void init_display() {
    BoardPower_Init();
    BoardPower_EPD_ON();
    BoardPower_Audio_ON();
    PortLvgl_Start_Init();
    Lvgl_PortInit(flush_display);

    if (Lvgl_lock(-1)) {
        connection_label = lv_label_create(lv_screen_active());
        lv_obj_set_width(connection_label, 176);
        lv_obj_set_style_text_align(connection_label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_set_style_text_font(connection_label, &lv_font_montserrat_14, 0);
        lv_label_set_text(connection_label, "Wi-Fi: not configured\nInternet: offline\nPhone relay: unavailable");
        lv_obj_align(connection_label, LV_ALIGN_TOP_MID, 0, 10);
        lv_obj_add_flag(connection_label, LV_OBJ_FLAG_HIDDEN);  // the splash is the boot screen

        message_label = lv_label_create(lv_screen_active());
        lv_obj_set_width(message_label, 176);
        lv_obj_set_style_text_align(message_label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_set_style_text_font(message_label, &lv_font_montserrat_14, 0);
        lv_label_set_long_mode(message_label, LV_LABEL_LONG_WRAP);
        lv_label_set_text(message_label, "Circuit\nStarting…");
        lv_obj_align(message_label, LV_ALIGN_BOTTOM_MID, 0, -12);
        lv_obj_add_flag(message_label, LV_OBJ_FLAG_HIDDEN);

        wordmark_image = lv_img_create(lv_screen_active());
        lv_img_set_src(wordmark_image, &circuit_splash_screen);
        lv_obj_center(wordmark_image);

        // The recording animation: a 64x64 image of its own, where the screen's ring used to be
        // (centred at 68,137, left of the timer). Shown only while recording.
        recording_icon = lv_img_create(lv_screen_active());
        lv_img_set_src(recording_icon, circuit_recording_frame(0));
        lv_obj_align(recording_icon, LV_ALIGN_TOP_LEFT, 36, 105);
        lv_obj_add_flag(recording_icon, LV_OBJ_FLAG_HIDDEN);

        // The "cannot record now" icon sits where the sync figure is (see show_busy_notice()).
        busy_icon_obj = lv_img_create(lv_screen_active());
        lv_img_set_src(busy_icon_obj, &circuit_icon_mic_off);
        lv_obj_align(busy_icon_obj, LV_ALIGN_TOP_LEFT, 116, 124);
        lv_obj_add_flag(busy_icon_obj, LV_OBJ_FLAG_HIDDEN);

        // Header icons: positioned and shown by refresh_status_icons().
        icon_wifi_obj = lv_img_create(lv_screen_active());
        icon_phone_obj = lv_img_create(lv_screen_active());
        icon_storage_obj = lv_img_create(lv_screen_active());
        for (lv_obj_t *icon : {icon_wifi_obj, icon_phone_obj, icon_storage_obj}) lv_obj_add_flag(icon, LV_OBJ_FLAG_HIDDEN);

        // Positions follow prototypes/circuit-epaper-states on the 200x200 panel.
        const auto make_label = [](const lv_font_t *font, lv_coord_t width, lv_text_align_t align) {
            lv_obj_t *label = lv_label_create(lv_screen_active());
            lv_obj_set_width(label, width);
            lv_obj_set_style_text_align(label, align, 0);
            lv_obj_set_style_text_font(label, font, 0);
            lv_obj_set_style_text_color(label, lv_color_black(), 0);
            lv_obj_set_style_bg_color(label, lv_color_white(), 0);
            lv_obj_set_style_bg_opa(label, LV_OPA_COVER, 0);
            lv_obj_add_flag(label, LV_OBJ_FLAG_HIDDEN);
            return label;
        };

        // The code sits inside the rounded box baked into the pair screen.
        pairing_code_label = make_label(&lv_font_montserrat_36, 150, LV_TEXT_ALIGN_CENTER);
        lv_obj_align(pairing_code_label, LV_ALIGN_TOP_LEFT, 25, 90);

        recording_timer_label = make_label(&lv_font_montserrat_24, 84, LV_TEXT_ALIGN_LEFT);
        lv_obj_set_style_text_letter_space(recording_timer_label, 1, 0);
        lv_obj_align(recording_timer_label, LV_ALIGN_TOP_LEFT, 116, 124);

        sync_progress_label = make_label(&lv_font_montserrat_24, 84, LV_TEXT_ALIGN_LEFT);
        lv_obj_set_style_text_letter_space(sync_progress_label, 1, 0);
        lv_obj_align(sync_progress_label, LV_ALIGN_TOP_LEFT, 116, 129);

        idle_date_label = make_label(&lv_font_montserrat_12, 100, LV_TEXT_ALIGN_LEFT);
        lv_obj_set_style_text_letter_space(idle_date_label, 1, 0);
        lv_obj_align(idle_date_label, LV_ALIGN_TOP_LEFT, 8, 7);

        idle_time_label = make_label(&lv_font_montserrat_36, LV_SIZE_CONTENT, LV_TEXT_ALIGN_LEFT);
        lv_obj_align(idle_time_label, LV_ALIGN_TOP_LEFT, 8, 36);

        idle_ampm_label = make_label(&lv_font_montserrat_12, LV_SIZE_CONTENT, LV_TEXT_ALIGN_LEFT);
        lv_obj_set_style_text_letter_space(idle_ampm_label, 1, 0);

        // Note counts: [clock]pending [check]done, right-aligned and laid out
        // by set_count_labels() so the icons stay beside their numbers.
        idle_done_label = make_label(&lv_font_montserrat_20, LV_SIZE_CONTENT, LV_TEXT_ALIGN_LEFT);
        lv_obj_align(idle_done_label, LV_ALIGN_TOP_RIGHT, -4, 43);
        idle_pending_label = make_label(&lv_font_montserrat_20, LV_SIZE_CONTENT, LV_TEXT_ALIGN_LEFT);
        idle_check_icon = lv_img_create(lv_screen_active());
        lv_img_set_src(idle_check_icon, &circuit_icon_check);
        lv_obj_add_flag(idle_check_icon, LV_OBJ_FLAG_HIDDEN);
        idle_clock_icon = lv_img_create(lv_screen_active());
        lv_img_set_src(idle_clock_icon, &circuit_icon_clock);
        lv_obj_add_flag(idle_clock_icon, LV_OBJ_FLAG_HIDDEN);

        lv_label_set_text(idle_date_label, "--- -- ---");
        lv_label_set_text(idle_time_label, "-:--");
        lv_label_set_text(idle_ampm_label, "");
        lv_label_set_text(idle_pending_label, "-");
        lv_label_set_text(idle_done_label, "-");
        layout_count_labels();
        Lvgl_unlock();
    }
}

}  // namespace

extern "C" void app_main(void) {
    boot_reset_reason = static_cast<int>(esp_reset_reason());
    ESP_LOGW(kTag, "Reset reason: %d (1=power-on 3=software 4=panic 5=int-wdt 6=task-wdt 7=wdt 9=brownout 15=brownout)",
        static_cast<int>(esp_reset_reason()));
    esp_err_t nvs_status = nvs_flash_init();
    if (nvs_status == ESP_ERR_NVS_NO_FREE_PAGES || nvs_status == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    } else {
        ESP_ERROR_CHECK(nvs_status);
    }

    crypto_self_test_ok = run_crypto_self_test();
    note_key_ready = circuit_secure::load_key(&note_key);
    ESP_LOGI(kTag, "Notes crypto self-test: %s; notes key: %s", crypto_self_test_ok ? "PASS" : "FAIL",
        note_key_ready ? "present" : "none yet");
    text_queue = xQueueCreate(4, sizeof(TextMessage));
    configASSERT(text_queue);
    pairing_passkey = esp_random() % 1000000;
    init_display();
    // Until the phone supplies its UTC offset, SNTP time is shown as IST.
    setenv("TZ", "IST-5:30", 1);
    tzset();
    // The "circuit" splash is already on screen. Get the home screen's values
    // ready behind it (saved counts, time zone, a clock that kept running) so it
    // is complete the moment it replaces the splash.
    restore_home_screen();
    init_sd_card();
    Codec_StartInit();
    audio_ready = true;
    init_record_button();
    xTaskCreate(demo_animation_task, "demo_animation", 3072, nullptr, 2, nullptr);
    // 5 KB: the command handler runs deep, through file listing and the Wi-Fi sync start, and
    // 4 KB overflowed once note listing grew by one nested call. Its real use is logged below.
    xTaskCreate(text_display_task, "text_display", 5120, nullptr, 4, nullptr);
    xTaskCreate(status_icon_task, "status_icons", 3072, nullptr, 2, nullptr);
    xTaskCreate(sync_supervisor_task, "sync_supervisor", 10240, nullptr, 3, nullptr);
    xTaskCreate(local_clock_task, "local_clock", 3072, nullptr, 2, nullptr);
    start_wifi();
    start_ble();
    // Start-up code is done, but give the splash time to be seen: about five seconds on the panel
    // (the board takes roughly two seconds after power-up to draw it, so leave at kSplashMinMs).
    // Home then opens with the clock kept from before, so it is not empty; Wi-Fi and the phone
    // connect in their own time and their icons update. If the clock somehow is not set, wait up
    // to kSplashMaxMs. If something has already taken over (a recording started with the button),
    // leave that alone.
    constexpr uint32_t kSplashMinMs = 7000;
    constexpr uint32_t kSplashMaxMs = 9000;
    const bool paired = esp_ble_get_bond_device_num() > 0;
    while (boot_splash) {
        const uint32_t up_ms = xTaskGetTickCount() * portTICK_PERIOD_MS;
        const bool ready = !paired || clock_set;
        if ((up_ms >= kSplashMinMs && ready) || up_ms >= kSplashMaxMs) {
            ESP_LOGI(kTag, "Leaving the splash after %u ms (clock %d, wifi %d, phone %d)",
                static_cast<unsigned>(up_ms), clock_set ? 1 : 0, wifi_ui != WifiUi::Connecting ? 1 : 0,
                ble_encrypted ? 1 : 0);
            break;
        }
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    ESP_LOGI(kTag, "Start-up done; internal RAM free %u, largest block %u",
        static_cast<unsigned>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL)),
        static_cast<unsigned>(heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL)));
    if (esp_ble_get_bond_device_num() == 0) {
        if (boot_splash) show_pairing_code();
    } else {
        // Paired before this firmware had notes encryption: make the key now. Older
        // notes stay exactly as they are; only new recordings are encrypted.
        ensure_note_key();
        if (boot_splash) show_device_screen(DeviceScreen::Idle);
    }
}
