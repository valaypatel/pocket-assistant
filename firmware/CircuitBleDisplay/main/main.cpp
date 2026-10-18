#include <atomic>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <cctype>
#include <ctime>
#include <mutex>
#include <new>

#ifdef CIRCUIT_DEV_CONSOLE
#include "driver/usb_serial_jtag.h"
#endif
#include "esp_app_desc.h"
#include "codec_init.h"
#include "esp_codec_dev.h"
#include "esp_ota_ops.h"
#include "esp_pm.h"
#include "driver/usb_serial_jtag.h"
#include "esp_sleep.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "circuit_sdlog.h"
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
#include "circuit_moment_icon.h"
#include "circuit_update_icon.h"
#include "circuit_recording_icon.h"
#include "circuit_battery.h"
#include "circuit_crypto.h"
#include "circuit_moments.h"
#include "circuit_notes.h"
#include "circuit_rtc.h"
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
uint64_t sd_free_bytes();
// The upper side button is the BOOT button (GPIO0). The lower GPIO18 button
// is power-related, so it deliberately remains outside the audio controls.
constexpr gpio_num_t kRecordButtonPin = GPIO_NUM_0;
// The lower key (GPIO18). A short press during a recording adds a Moment. Longer than this is not a tap.
#ifndef CIRCUIT_DEV_CONSOLE
constexpr gpio_num_t kLowerKeyPin = GPIO_NUM_18;
#endif
constexpr uint32_t kLowerTapMaxMs = 600;
// GPIO17 holds the battery connected. On USB the board runs without it, but on the battery it would
// switch off as soon as the power key is let go. Pressing the lower key this long (not while recording
// or syncing) turns the board off.
constexpr gpio_num_t kBatteryLatchPin = GPIO_NUM_17;
constexpr uint32_t kPowerOffHoldMs = 3000;
// The cell is flat below about this voltage; switching off here protects it.
constexpr int kBatteryEmptyMv = 3250;
// At or below this charge the header says LOW instead of a number (the phone is told as well).
constexpr int kBatteryLowPercent = 15;
// Below this the cell is in danger, whatever Circuit is doing.
constexpr int kBatteryHardFloorMv = 3000;
// A cell being charged climbs; one being used only falls. A rise of this much between two readings means
// USB is charging it, which is the only way to tell, as the board has no USB-power sense line.
constexpr int kBatteryRisingMv = 5;
// Plugging a charger in lifts the terminal voltage at once (about 160 mV at 3.7 V), long before the cell has
// taken any charge; unplugging drops it again. A step this big between two readings is that, not chemistry.
constexpr int kBatteryChargeStepMv = 60;
// Under the highest reading of a charge by this much: the charger has stopped (cell full), the voltage is resting.
constexpr int kBatteryChargeEndMv = 30;
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
lv_obj_t *recording_moment_icon;   // a bookmark under the timer: the cue that a lower-key tap was taken
lv_obj_t *recording_moment_count;  // beside it: how many taps this recording has
std::atomic<uint32_t> recording_moments{0};  // taps taken in the current recording
std::atomic<int64_t> moment_cue_until_ms{0};  // the cue is shown until then (esp_timer time in ms)
constexpr int64_t kMomentCueMs = 3000;
lv_obj_t *recording_icon;  // the animated device icon on the recording screen (64x64)
lv_obj_t *sync_progress_label;
bool zzz_shown = false;
lv_obj_t *sleep_zzz_label;  // "zzz" under the wordmark on the idle screen while light sleep is on (nothing is happening)
lv_obj_t *update_cog_obj;  // the turning cog of a firmware update (circuit_update_icon.h), with the percentage below
bool update_screen_active = false;
int update_frame = 0;
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
// Signal strength of the current link as the board hears the phone, sampled every 20 s, so a drop can be
// put next to how weak the link was just before it.
uint8_t peer_bda[6] = {};
int last_rssi_dbm = 0;
int64_t last_rssi_at_us = 0;
sdmmc_card_t *sd_card = nullptr;
bool audio_ready = false;
// One thing at a time uses the microphone, speaker and the note being sent. It is claimed with
// claim_audio() so two requests arriving together (the key and the app) cannot both win.
std::atomic<bool> audio_busy{false};
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
enum class WifiUi : uint8_t { None, Connecting, Connected, Failed, Resting };  // Resting: switched off to save power
volatile WifiUi wifi_ui = WifiUi::None;
char wifi_ssid[33] = "";
char wifi_detail[48] = "";  // IP address when connected, reason when failed
int wifi_retries = 0;
bool wifi_manual_disconnect = false;  // we asked for the next DISCONNECTED event
bool wifi_auth_failure = false;
int64_t wifi_failed_at_ms = 0;
constexpr int kWifiMaxRetries = 4;
lv_obj_t *icon_wifi_obj;
// Battery in the header: an outline, a fill that follows the charge, a small tip, and the number.
lv_obj_t *battery_body;
lv_obj_t *battery_fill;
lv_obj_t *battery_nub;
lv_obj_t *battery_bolt;  // inside the battery body while USB is charging
lv_obj_t *battery_label;
// The charge shown, 0 to 100 in steps of 5; -1 until the first reading.
volatile int battery_percent = -1;
volatile bool battery_charging = false;  // USB is pushing current in: the voltage reads high (see battery_tick)
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
TaskHandle_t sync_supervisor_handle = nullptr;  // woken when a session opens, so it is not polled while none is
bool sntp_started = false;
constexpr time_t kMinValidEpoch = 1704067200;  // 2024-01-01

void send_relay_request(const char *request);
void show_busy_notice();
// The audio chip's data link (I2S) is open only while something records or plays. Left open, it holds the
// processor at full speed and awake all day (and keeps the codec and amplifier running), which blocks every kind
// of power saving. Waveshare's init opens both directions and leaves them open: Codec_StartInit() is followed by
// audio_devices_close(), and claim_audio() / release_audio() open and close them around each use.
bool audio_devices_opened = false;

void audio_devices_open() {
    if (audio_devices_opened) return;
    esp_codec_dev_sample_info_t format = {};
    format.sample_rate = 16000;
    format.channel = 2;
    format.bits_per_sample = 16;
    esp_codec_dev_handle_t speaker = get_playback_handle();
    esp_codec_dev_handle_t microphone = get_record_handle();
    ESP_ERROR_CHECK_WITHOUT_ABORT(esp_codec_dev_open(speaker, &format));
    ESP_ERROR_CHECK_WITHOUT_ABORT(esp_codec_dev_open(microphone, &format));
    ESP_ERROR_CHECK_WITHOUT_ABORT(esp_codec_dev_set_out_vol(speaker, 100));  // the same as Codec_StartInit() sets
    ESP_ERROR_CHECK_WITHOUT_ABORT(esp_codec_dev_set_in_gain(microphone, 45.0));
    audio_devices_opened = true;
}

void audio_devices_close() {
    if (!audio_devices_opened) return;
    esp_codec_dev_close(get_playback_handle());
    esp_codec_dev_close(get_record_handle());
    audio_devices_opened = false;
}

bool claim_audio() {
    if (audio_busy.exchange(true)) return false;
    audio_devices_open();
    return true;
}

// Gives the audio back: closes the chip's data link, then lets the next request claim it.
void release_audio() {
    audio_devices_close();
    audio_busy = false;
}

// A firmware update is under way: from when Circuit offers the phone an update session until the new
// firmware is in place (set once the image has arrived, while it is written). While it is, nothing that
// would interrupt it is allowed: recording, playing, syncing, a broadcast, and switching off.
TaskHandle_t animation_task_handle = nullptr;  // woken when the screen changes, so it can sleep while nothing animates
TaskHandle_t record_button_handle = nullptr;  // the record key's task; woken by its interrupt (and by the dev console)
// ---- Power modes ----------------------------------------------------------
// The battery decides how much the board does (the phone can only ask for more saving, never less):
//   Saver       above 35%: light sleep, everything works.
//   Deep        35% down to 10%: the radios are used sparingly (see the stages in docs/power-modes.md).
//   RecordOnly  10% or below: it records, and nothing else: no sync, no broadcast, no update, no playback.
// A tier is entered at its threshold and left 5 points higher, so a reading that wobbles with load does not flip it.
enum class PowerMode : uint8_t { Saver = 0, Deep = 1, RecordOnly = 2 };
enum class PowerChoice : uint8_t { Auto = 0, Saver = 1, Deep = 2 };  // what the phone asks for
constexpr int kDeepBelowPercent = 35;       // at or below: Deep
constexpr int kRecordOnlyBelowPercent = 10;  // at or below: RecordOnly
constexpr int kTierMarginPercent = 5;
PowerMode power_auto_mode = PowerMode::Saver;       // from the battery
PowerChoice power_choice = PowerChoice::Auto;       // from the phone, kept across restarts
PowerMode effective_power_mode() {
    // The phone can ask for Deep early; it can never lift the board out of a tier the battery has put it in.
    PowerMode wanted = power_choice == PowerChoice::Deep ? PowerMode::Deep : PowerMode::Saver;
    return static_cast<uint8_t>(power_auto_mode) > static_cast<uint8_t>(wanted) ? power_auto_mode : wanted;
}
bool recording_only() { return effective_power_mode() == PowerMode::RecordOnly; }
const char *power_mode_name(PowerMode mode) {
    return mode == PowerMode::RecordOnly ? "rec" : mode == PowerMode::Deep ? "deep" : "saver";
}

// ---- Radios in Deep ---------------------------------------------------------
// Below the Saver tier the board keeps the phone's Bluetooth link but slows it right down (an event about once a
// second, so a message from the phone still arrives within a few seconds), and rests Wi-Fi, the big cost, until a
// sync, a broadcast or an update needs it: then it is switched on, the board waits for it, and does the job.
bool wifi_resting = false;
int64_t wifi_last_needed_ms = 0;  // when something last used Wi-Fi or asked for it
constexpr int64_t kWifiIdleBeforeRestMs = 60000;
enum class AfterWifi : uint8_t { Nothing, Sync, Broadcast, Update };
volatile AfterWifi after_wifi = AfterWifi::Nothing;  // what to do once Wi-Fi is up again
bool after_wifi_forced = false;
void request_after_wifi(AfterWifi action, bool forced);
void wifi_wake();
void wifi_rest();
void apply_ble_rhythm();
void apply_power_policy();
uint8_t connected_bda[6] = {};
bool adv_restart_pending = false;
bool ble_seen_since_boot = false;  // a phone has connected and secured the link since the board started
bool light_sleep_pinned_off = false;  // the development console asked for it off: stay off
bool usb_host_connected = false;      // a computer is on the USB cable: the board stays awake (see update_usb_awake)
esp_pm_lock_handle_t usb_awake_lock = nullptr;
bool light_sleep_on = false;  // see "Light sleep" further down
void set_light_sleep(bool on);
void log_power_use();
std::atomic<bool> firmware_installing{false};
bool update_busy() { return firmware_installing.load() || (circuit_sync::is_open() && circuit_sync::state.firmware); }

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
    // 100 to 200 ms (units of 0.625 ms). The phone finds the board within a fraction of a second either way, and a
    // board waiting for its phone no longer sends 25 to 50 advertisements a second.
    .adv_int_min = 0xA0,
    .adv_int_max = 0x140,
    .adv_type = ADV_TYPE_IND,
    .own_addr_type = BLE_ADDR_TYPE_PUBLIC,
    .channel_map = ADV_CHNL_ALL,
    .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

esp_ble_adv_data_t adv_data = {
    .set_scan_rsp = false,
    .include_name = true,
    .include_txpower = false,
    // The connection rhythm the board prefers (units of 1.25 ms): 100 to 200 ms. It carries short commands and
    // status; files go over Wi-Fi. (The old 7.5 to 20 ms woke the board 50 to 130 times a second.)
    .min_interval = 0x0050,
    .max_interval = 0x00A0,
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

// With `only_if_showing` set, the change is made only if that screen is still the one showing. The check
// is made under the display lock, so a screen that took over meanwhile (a new recording right after a
// save) is never overwritten by a timer that was set for the old one.
void show_device_screen(DeviceScreen screen, bool only_if_showing = false, DeviceScreen showing = DeviceScreen::Idle);

// Date, clock and note counts stay on screen in every state (see
// prototypes/circuit-epaper-states). They only appear once the phone has
// supplied real values; until then they show dashes. The pairing screen
// keeps its baked "PAIR CODE" header in place of the date.
int persistent_applied = -1;  // the screen these labels were last arranged for; -1 forces a fresh arrangement

// The e-paper is redrawn with quick partial refreshes, which leave faint traces of what was there before (the
// clock, behind the update cog). A full refresh wipes them, at the cost of a flash lasting a second or two, so
// it is done only when the screen changes a lot, from the status task once the new picture has been drawn.
volatile bool ghost_clear_pending = false;

void epaper_full_refresh() {
    if (!Lvgl_lock(-1)) return;
    EPD_Init();                  // the full-refresh waveform
    EPD_DisplayPartBaseImage();  // the picture just drawn, shown in full, and kept as the base for partial updates
    EPD_Init_Partial();          // back to quick updates
    Lvgl_unlock();
}

void apply_persistent_labels(DeviceScreen screen) {
    if (boot_splash) return;
    // Moving objects to the foreground redraws the screen, so only do it when the
    // screen actually changed.
    if (persistent_applied == static_cast<int>(screen)) return;
    persistent_applied = static_cast<int>(screen);
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
    circuit_rtc::write(epoch);  // so the next power-up starts with the right time
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

// The real-time clock chip keeps UTC while the board is off. Use it when the system clock was lost
// (power was cut). Needs the codec started first: that is what opens the I2C bus.
void restore_clock_from_rtc() {
    circuit_rtc::init();
    time_t from_chip = 0;
    const bool chip_ok = circuit_rtc::read(&from_chip, kMinValidEpoch);
    const time_t now = time(nullptr);
    if (chip_ok && now < kMinValidEpoch) {
        timeval tv = {.tv_sec = from_chip, .tv_usec = 0};
        settimeofday(&tv, nullptr);
        clock_set = true;
        if (Lvgl_lock(-1)) {
            show_local_time(from_chip);
            Lvgl_unlock();
        }
        ESP_LOGW(kTag, "Clock restored from the RTC chip: %lld", static_cast<long long>(from_chip));
    } else {
        ESP_LOGW(kTag, "RTC chip: %s; system clock %s", chip_ok ? "holds a time" : "has no valid time",
            now >= kMinValidEpoch ? "kept" : "not set");
        // The system clock was kept but the chip is empty or behind: teach the chip.
        if (now >= kMinValidEpoch && (!chip_ok || from_chip + 120 < now || from_chip > now + 120)) {
            circuit_rtc::write(now);
        }
    }
}

// What the count labels show now (-1: nothing drawn yet). The phone sends both numbers; the waiting one is also
// kept right by the board itself, from its own card, so a recording shows at once and a finished sync clears it.
int home_shown_pending = -1;
int home_shown_done = -1;
int card_pending = -1;  // recordings waiting, counted from the card (-1: not counted yet); it beats the phone's figure

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
    if (epoch != nullptr && offset != nullptr) {
        const time_t phone_now = static_cast<time_t>(strtoll(epoch, nullptr, 10));
        const time_t board_now = ::time(nullptr);
        // Set it when none is set yet, or when the board is off by more than two minutes (the RTC
        // or the clock drifted, or the RTC held an old value). Small differences are left alone.
        if (!clock_set || (phone_now >= kMinValidEpoch && (phone_now > board_now ? phone_now - board_now : board_now - phone_now) > 120)) {
            set_clock_from_phone(phone_now, atoi(offset));
        }
    }
    // The phone repeats this message often. Touching the labels redraws the whole
    // e-paper, so do nothing when it matches what is already shown.
    int hour = 0, minute = 0, pending = 0, done = 0;
    const bool time_ok = sscanf(time, "%d:%d", &hour, &minute) == 2;
    const bool counts_ok = sscanf(counts, "%d %*[^0-9]%d", &pending, &done) == 2;
    if (counts_ok && card_pending >= 0) pending = card_pending;  // the phone's waiting count can be a step behind
    static int shown_clock = -1;
    const int clock_key = hour * 60 + minute;
    if (counts_ok && offset != nullptr) {
        save_home_snapshot({pending, done, atoi(offset)});
    }
    const bool same = home_status_received && counts_ok && pending == home_shown_pending && done == home_shown_done &&
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
        home_shown_pending = pending;
        home_shown_done = done;
    }
    ESP_LOGI(kTag, "Home status: counts=%d/%d clock_set=%d", pending, done, clock_set ? 1 : 0);
    apply_persistent_labels(active_screen);
    Lvgl_unlock();
}

// Puts the number of recordings waiting on the card on the home screen, without waiting for the phone to say so.
// The synced count stays whatever the phone last said (it is the phone's own count of notes it holds).
void show_pending_from_card() {
    if (sd_card == nullptr) return;
    const int pending = static_cast<int>(circuit_notes::count_unsynced_recordings());
    card_pending = pending;
    if (pending == home_shown_pending) return;
    const int done = home_shown_done >= 0 ? home_shown_done : (saved_home.done >= 0 ? saved_home.done : 0);
    if (!Lvgl_lock(-1)) return;
    set_count_labels(pending, done);
    home_shown_pending = pending;
    home_shown_done = done;
    Lvgl_unlock();
    ESP_LOGI(kTag, "Home counts from the card: %d waiting", pending);
}

void screen_timeout_task(void *argument) {
    const ScreenTimeout timeout = *static_cast<ScreenTimeout *>(argument);
    delete static_cast<ScreenTimeout *>(argument);
    vTaskDelay(pdMS_TO_TICKS(timeout.delay_ms));
    if (!(timeout.expected == DeviceScreen::Playback && playback_active.load())) {
        show_device_screen(DeviceScreen::Idle, true, timeout.expected);
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

void show_device_screen(DeviceScreen screen, bool only_if_showing, DeviceScreen showing) {
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
    if (only_if_showing && active_screen != showing) {
        Lvgl_unlock();
        return;
    }
    active_screen = screen;
    boot_splash = false;
    if (animation_task_handle != nullptr) xTaskNotifyGive(animation_task_handle);
    if (screen == DeviceScreen::Recording) {
        recording_started_at = xTaskGetTickCount();
    }
    lv_obj_add_flag(connection_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(message_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(pairing_code_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(recording_timer_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(recording_moment_icon, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(recording_moment_count, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(recording_icon, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(sync_progress_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(busy_icon_obj, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(update_cog_obj, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(sleep_zzz_label, LV_OBJ_FLAG_HIDDEN);  // refresh_status_icons() shows it again on the idle screen
    zzz_shown = false;
    if (update_screen_active) {  // the sync figure goes back to its own size and place
        update_screen_active = false;
        persistent_applied = -1;  // and the clock and counts, hidden for the update, come back
        ghost_clear_pending = true;  // and the cog's traces are wiped
        lv_obj_set_style_text_font(sync_progress_label, &lv_font_montserrat_24, 0);
        lv_obj_set_width(sync_progress_label, 84);
        lv_obj_set_style_text_align(sync_progress_label, LV_TEXT_ALIGN_LEFT, 0);
        lv_obj_align(sync_progress_label, LV_ALIGN_TOP_LEFT, 116, 129);
    }
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
                    // The cue that a lower-key tap was taken: a bookmark under the timer with the number of
                    // taps beside it, for about three seconds after each tap. It is drawn here, with the
                    // rest of this screen, because the key task must not wait for the e-paper's refresh.
                    // The bookmark stays the same; only the number changes, so it never reads as a switch.
                    const uint32_t taken = recording_moments.load();
                    if (taken > 0 && esp_timer_get_time() / 1000 < moment_cue_until_ms.load()) {
                        char count_text[12];
                        snprintf(count_text, sizeof(count_text), "%lu", static_cast<unsigned long>(taken));
                        lv_label_set_text(recording_moment_count, count_text);
                        lv_obj_clear_flag(recording_moment_icon, LV_OBJ_FLAG_HIDDEN);
                        lv_obj_clear_flag(recording_moment_count, LV_OBJ_FLAG_HIDDEN);
                    } else {
                        lv_obj_add_flag(recording_moment_icon, LV_OBJ_FLAG_HIDDEN);
                        lv_obj_add_flag(recording_moment_count, LV_OBJ_FLAG_HIDDEN);
                    }
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
            // Nothing is animating: sleep until the screen changes (show_device_screen wakes this task), with a
            // long timeout as a safety net. It used to wake seven times a second for nothing.
            ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(5000));
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
    lv_obj_add_flag(recording_moment_icon, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(recording_icon, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(sync_progress_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(busy_icon_obj, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(update_cog_obj, LV_OBJ_FLAG_HIDDEN);
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
        circuit_sdlog::room_ok = [] { return sd_free_bytes() > 3 * kMinFreeCardBytes; };
        circuit_sdlog::start_writer();
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
    recording_paused = false;
    recording_active = false;
    playback_active = false;
    release_audio();
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

// Frees room on the card by removing the oldest recordings the phone has confirmed, until there is
// twice the minimum free. Notes still waiting to sync are never removed. False if that was not
// enough.
bool free_card_room() {
    const uint64_t target = 2 * kMinFreeCardBytes;
    while (sd_free_bytes() < target) {
        const size_t removed = circuit_notes::remove_oldest_synced_recording();
        if (removed == 0) return false;
        ESP_LOGW(kTag, "Card nearly full: removed %u synced note(s) to make room", static_cast<unsigned>(removed));
    }
    return true;
}

// A tap on the lower key during a recording asks for a Moment. The key task only counts; the
// recording loop turns each request into an offset within the current part (the audio position,
// so pauses do not count).
std::atomic<uint32_t> moment_requests{0};

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
    if (sd_free_bytes() < kMinFreeCardBytes && !free_card_room()) {
        update_storage_status("Card is full\nFree some space");
        report_audio_status("Recording failed: the card is full");
        finish_audio_task();
        return;
    }

    recording_audio_ms = 0;
    recording_paused = false;
    recording_moments = 0;
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
    uint32_t moments[circuit_moments::kMaxPerPart];  // offsets in the current part, in ms
    size_t moment_count = 0;
    uint32_t moments_taken = moment_requests.load();  // requests already turned into offsets
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
            if (moment_count > 0 && !circuit_moments::save(current_id, note_key, moments, moment_count)) {
                ESP_LOGW(kTag, "Could not save the moments of part %lu", static_cast<unsigned long>(part));
            }
            moment_count = 0;
            circuit_notes::write_group(current_id, {first_id, part, false});
            previous_id = current_id;
            if (sd_free_bytes() < kMinFreeCardBytes && !free_card_room()) {
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
        // Taps since the last buffer sit at the end of the audio written so far (about one buffer of
        // accuracy, under a tenth of a second).
        for (uint32_t pending = moment_requests.load(); moments_taken != pending; ++moments_taken) {
            if (moment_count < circuit_moments::kMaxPerPart) {
                moments[moment_count++] = static_cast<uint32_t>(static_cast<uint64_t>(part_bytes) * 1000 / header.byte_rate);
                ESP_LOGW(kTag, "Moment %u in part %lu at %lu ms", static_cast<unsigned>(moment_count),
                    static_cast<unsigned long>(part), static_cast<unsigned long>(moments[moment_count - 1]));
            }
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
        } else if (moment_count > 0 && !circuit_moments::save(current_id, note_key, moments, moment_count)) {
            ESP_LOGW(kTag, "Could not save the moments of part %lu", static_cast<unsigned long>(part));
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
    show_pending_from_card();
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

// Plays the message the phone sent (circuit_sync::kSpeakPath, already checked) and deletes it. It is
// not a note: nothing about it is kept, listed or synced.
void speak_audio_task(void *) {
    show_device_screen(DeviceScreen::Playback);
    update_storage_status("Message from phone");
    report_audio_status("Playing message from phone");
    FILE *file = fopen(circuit_sync::kSpeakPath, "rb");
    auto *buffer = static_cast<uint8_t *>(heap_caps_malloc(kAudioBufferBytes, MALLOC_CAP_SPIRAM));
    auto *stereo_buffer = static_cast<uint8_t *>(heap_caps_malloc(kAudioBufferBytes * 2, MALLOC_CAP_SPIRAM));
    bool played = false;
    bool failed = file == nullptr || buffer == nullptr || stereo_buffer == nullptr;
    if (!failed && fseek(file, circuit_sync::kSpeakHeaderBytes, SEEK_SET) == 0) {
        size_t bytes = 0;
        while (!playback_stop_requested.load() && (bytes = fread(buffer, 1, kAudioBufferBytes, file)) > 0) {
            if (!play_mono_chunk(buffer, bytes, stereo_buffer)) { failed = true; break; }
            played = true;
            playback_audio_ms.fetch_add(static_cast<uint32_t>(bytes * 1000 / (kAudioSampleRate * 2)));
        }
    }
    if (file != nullptr) fclose(file);
    if (buffer != nullptr) heap_caps_free(buffer);
    if (stereo_buffer != nullptr) heap_caps_free(stereo_buffer);
    remove(circuit_sync::kSpeakPath);
    if (playback_stop_requested.load()) {
        report_audio_status("Playback stopped");
    } else if (failed || !played) {
        update_storage_status("Playback failed\nCould not play message");
        report_audio_status("Broadcast failed: could not play the message");
    } else {
        report_audio_status("Broadcast played");
    }
    if (Lvgl_lock(-1)) {
        lv_obj_add_flag(recording_timer_label, LV_OBJ_FLAG_HIDDEN);
        Lvgl_unlock();
    }
    return_to_idle_after(DeviceScreen::Playback, 2500);
    finish_audio_task();
}

// Starts playing the message that just arrived. If the speaker is taken, the message is dropped.
void start_speak_playback() {
    if (recording_only() || update_busy() || !claim_audio()) {
        remove(circuit_sync::kSpeakPath);
        report_audio_status("Broadcast failed: Circuit is busy");
        return;
    }
    playback_stop_requested = false;
    playback_audio_ms = 0;
    playback_active = true;
    if (xTaskCreate(speak_audio_task, "audio_speak", 6144, nullptr, 5, nullptr) != pdPASS) {
        playback_active = false;
        release_audio();
        remove(circuit_sync::kSpeakPath);
        report_audio_status("Broadcast failed: could not start playback");
    }
}

void start_recording(char *command) {
    if (update_busy()) {  // a recording would be lost to the restart, or cut the update short
        report_audio_status("Cannot record while Circuit is updating");
        return;
    }
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
    if (circuit_sync::is_open() || !free_audio_from_playback()) {
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
        release_audio();
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
    static const char *const names[] = {"none", "connecting", "connected", "failed", "resting"};
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
bool previous_firmware(char *version, size_t version_size, char *build, size_t build_size);

void send_sync_status() {
    char message[kMaxTextBytes + 1];
    // What the card says is worked out at most once a minute, and the other firmware once: each of these reads
    // the card or the flash, and the phone may ask several times.
    static int64_t card_checked_ms = -1000000;
    static char card[40] = "";
    if (circuit_sync::now_ms() - card_checked_ms > 60000) {
        card_checked_ms = circuit_sync::now_ms();
        card[0] = '\0';
        uint64_t card_total = 0, card_free = 0;
        if (esp_vfs_fat_info(kSdMountPath, &card_total, &card_free) == ESP_OK && card_total > 0) {
            snprintf(card, sizeof(card), "%llu|%llu", static_cast<unsigned long long>((card_total - card_free) / 1024),
                static_cast<unsigned long long>(card_total / 1024));
        }
    }
    static bool previous_known = false;
    static char previous[48] = "";
    if (!previous_known) {
        previous_known = true;
        char previous_version[32] = "", previous_build[9] = "";
        if (previous_firmware(previous_version, sizeof(previous_version), previous_build, sizeof(previous_build))) {
            snprintf(previous, sizeof(previous), "%s|%s", previous_version, previous_build);
        }
    }
    const unsigned waiting = card_pending >= 0 ? static_cast<unsigned>(card_pending)
                                               : static_cast<unsigned>(circuit_notes::count_unsynced_recordings());
    // The first three lines are what the app has always read; the rest is board health,
    // forwarded to the app's diagnostics (counts and sizes only).
    snprintf(message, sizeof(message),
        "@sync-status\nwaiting=%u\nreset=%d\nuptime=%lld\nfree_min=%u\nstack_min=%u\nstops=%u\nbat=%d",
        waiting, boot_reset_reason,
        static_cast<long long>(circuit_sync::now_ms() / 1000),
        static_cast<unsigned>(heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL)),
        static_cast<unsigned>(text_stack_min_bytes == UINT32_MAX ? 0 : text_stack_min_bytes),
        static_cast<unsigned>(circuit_sync::download_stops), battery_percent);
    send_relay_request(message);
    // A separate short snapshot keeps both packets within the 160-byte BLE limit.
    // "recording" lets the app drop a recording indicator that outlived a restart of the board.
    snprintf(message, sizeof(message), "@sync-status\nplayback=%s\nplayback_ms=%lu\nplayback_stop=1\nrecording=%s",
        playback_active.load() ? "playing" : "idle",
        static_cast<unsigned long>(playback_active.load() ? playback_audio_ms.load() : 0),
        recording_active ? (recording_paused ? "paused" : "recording") : "idle");
    send_relay_request(message);
    // And a third, about what is installed and what is stored:
    //   fw   the firmware that is running: its version, then the first eight hex digits of its build
    //        fingerprint (the app reads the same digits from a firmware file; no two builds share them)
    //   prev the firmware that "go back" would switch to (empty when there is none)
    //   sd   the card's space in use, then its total size, in KB (absent without a card)
    char build_id[9] = "";
    esp_app_get_elf_sha256(build_id, sizeof(build_id));
    snprintf(message, sizeof(message), "@sync-status\nfw=%.20s|%s\nprev=%.40s\nsd=%.30s\npm=%s|%s",
        esp_app_get_description()->version, build_id, previous, card, power_mode_name(effective_power_mode()),
        power_choice == PowerChoice::Deep ? "deep" : power_choice == PowerChoice::Saver ? "saver" : "auto");
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
void power_off(const char *message);

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
    static int shown_battery = -2;
    const int battery = battery_percent < 0 ? battery_percent : battery_percent + (battery_charging ? 1000 : 0);
    // "zzz" says the board is in its sleeping mode and idle: it goes as soon as something wakes it up to work
    // (a recording, playback, a sync, an update), and comes back to the idle screen. Redrawn only when it flips.
    const bool zzz = light_sleep_on && !usb_host_connected && active_screen == DeviceScreen::Idle;
    if (zzz != zzz_shown && Lvgl_lock(-1)) {
        zzz_shown = zzz;
        if (zzz) {
            lv_obj_clear_flag(sleep_zzz_label, LV_OBJ_FLAG_HIDDEN);
            lv_obj_move_foreground(sleep_zzz_label);
        } else {
            lv_obj_add_flag(sleep_zzz_label, LV_OBJ_FLAG_HIDDEN);
        }
        Lvgl_unlock();
    }
    if (wifi_src == shown_wifi && state == shown_state && battery == shown_battery) return;
    if (!Lvgl_lock(-1)) return;
    shown_wifi = wifi_src;
    shown_state = state;
    shown_battery = battery;
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
    // Battery, to the left of the other icons: [number][body][tip].
    const bool charging = battery >= 1000;
    const int level = charging ? battery - 1000 : battery;
    if (battery < 0) {
        for (lv_obj_t *part : {battery_body, battery_nub, battery_label}) lv_obj_add_flag(part, LV_OBJ_FLAG_HIDDEN);
    } else {
        const int body_x = x_right - 18;
        lv_obj_set_pos(battery_body, body_x, 6);
        lv_obj_set_pos(battery_nub, body_x + 16, 8);
        int fill = (level * 12 + 50) / 100;
        if (level > 0 && fill < 1) fill = 1;
        lv_obj_set_size(battery_fill, fill, 6);
        lv_obj_set_style_bg_opa(battery_fill, fill > 0 ? LV_OPA_COVER : LV_OPA_TRANSP, 0);
        char text[16];
        if (level <= kBatteryLowPercent) {
            snprintf(text, sizeof(text), "LOW");
        } else {
            snprintf(text, sizeof(text), "%d", level);
        }
        if (charging) lv_obj_clear_flag(battery_bolt, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(battery_bolt, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(battery_label, text);
        lv_obj_update_layout(battery_label);
        lv_obj_set_pos(battery_label, body_x - 3 - lv_obj_get_width(battery_label), 5);
        for (lv_obj_t *part : {battery_body, battery_nub, battery_label}) lv_obj_clear_flag(part, LV_OBJ_FLAG_HIDDEN);
        lv_obj_move_foreground(battery_label);  // never under the date
    }
    Lvgl_unlock();
}

// Reads the battery about every 30 s (the status icon task ticks every 0.9 s), skipping moments of heavy
// load, when the voltage sags and would read low. The median of the last five readings is rounded to steps
// of 5 and only changes when it has really moved, so the screen is not redrawn for noise. A change is also
// sent to the phone.
// Chooses the battery's tier for this charge. Returns true when it changed.
bool update_power_mode(int percent) {
    if (percent < 0) return false;
    PowerMode next = power_auto_mode;
    switch (power_auto_mode) {
    case PowerMode::Saver:
        if (percent <= kRecordOnlyBelowPercent) next = PowerMode::RecordOnly;
        else if (percent <= kDeepBelowPercent) next = PowerMode::Deep;
        break;
    case PowerMode::Deep:
        if (percent <= kRecordOnlyBelowPercent) next = PowerMode::RecordOnly;
        else if (percent >= kDeepBelowPercent + kTierMarginPercent) next = PowerMode::Saver;
        break;
    case PowerMode::RecordOnly:
        if (percent >= kDeepBelowPercent + kTierMarginPercent) next = PowerMode::Saver;
        else if (percent >= kRecordOnlyBelowPercent + kTierMarginPercent) next = PowerMode::Deep;
        break;
    }
    if (next == power_auto_mode) return false;
    ESP_LOGW(kTag, "Power mode by battery: %s -> %s (%d%%)", power_mode_name(power_auto_mode), power_mode_name(next), percent);
    power_auto_mode = next;
    return true;
}

void save_power_choice() {
    nvs_handle_t handle;
    if (nvs_open("power", NVS_READWRITE, &handle) != ESP_OK) return;
    nvs_set_u8(handle, "choice", static_cast<uint8_t>(power_choice));
    nvs_commit(handle);
    nvs_close(handle);
}

void load_power_choice() {
    nvs_handle_t handle;
    uint8_t value = 0;
    if (nvs_open("power", NVS_READONLY, &handle) != ESP_OK) return;
    if (nvs_get_u8(handle, "choice", &value) == ESP_OK && value <= static_cast<uint8_t>(PowerChoice::Deep)) {
        power_choice = static_cast<PowerChoice>(value);
    }
    nvs_close(handle);
}

void battery_tick() {
    static int ticks = 0;
    static int samples[5];
    static int count = 0;
    if (++ticks % 33 != 1) return;
    if (recording_active || playback_active.load() || active_screen == DeviceScreen::Syncing) return;
    const int mv = circuit_battery::read_mv();
    if (mv <= 0) return;
    samples[count % 5] = mv;
    count++;
    // A line every ten readings (about five minutes) in the log on the card, with what the board is doing, so
    // a fast-draining battery can be read back from the card later: how fast, and with what running.
    static int logged = 0;
    if (logged++ % 10 == 0) {
        ESP_LOGI(kTag, "Battery log: %d mV, uptime %lld s, phone %s, wifi %s%s", mv,
            static_cast<long long>(circuit_sync::now_ms() / 1000), connection_id != UINT16_MAX ? "connected" : "no",
            wifi_ui == WifiUi::Connected ? "connected" : (wifi_ui == WifiUi::None ? "off" : (wifi_ui == WifiUi::Resting ? "resting" : "trying")),
            update_busy() ? ", updating" : "");
        log_power_use();
    }
    int sorted[5];
    const int n = count < 5 ? count : 5;
    for (int i = 0; i < n; i++) sorted[i] = samples[i];
    for (int i = 1; i < n; i++) {
        for (int j = i; j > 0 && sorted[j - 1] > sorted[j]; j--) {
            const int t = sorted[j];
            sorted[j] = sorted[j - 1];
            sorted[j - 1] = t;
        }
    }
    // Flat on three readings in a row, and not being charged (a charging cell's voltage keeps climbing, a
    // flat cell on its own only falls): switch off to protect the cell, while there is still enough charge
    // to do it cleanly.
    static int flat = 0;
    static int previous_mv = 0;
    const int median_mv = sorted[n / 2];
    const bool charging = previous_mv > 0 && median_mv >= previous_mv + kBatteryRisingMv;
    previous_mv = median_mv;
    // An update is never cut short by the empty-battery switch-off (a power loss mid-update is safe anyway:
    // the old firmware stays valid until the last step), unless the cell is close to damage.
    const bool defer = update_busy() && median_mv >= kBatteryHardFloorMv;
    flat = (median_mv < kBatteryEmptyMv && !charging && !defer) ? flat + 1 : 0;
    if (flat >= 3) {
        power_off("Battery empty\nCharge it, then hold\nthe power key");
        return;
    }
    // Charging: take the push of the charger off the reading (about 150 mV at 3.8 V, less as the cell fills; the
    // charger ends the cycle at about 4.2 V terminal, 4.12 V resting), and never let the figure fall while it
    // lasts. Unplugged, it settles back on the resting reading.
    static int last_mv = 0;
    const int step = last_mv > 0 ? mv - last_mv : 0;
    last_mv = mv;
    static bool by_step = false;
    static bool host_before = false;
    if (step >= kBatteryChargeStepMv) by_step = true;
    else if (step <= -kBatteryChargeStepMv || (host_before && !usb_host_connected)) by_step = false;
    host_before = usb_host_connected;
    // The charger ends its cycle when the cell is full and the voltage then sags back to its resting value; a
    // reading well under the highest one of this charge means nothing is being pushed in any more.
    static int peak_mv = 0;
    static bool finished = false;
    if (!by_step) { peak_mv = 0; finished = false; }
    else if (mv > peak_mv) { peak_mv = mv; finished = false; }
    else if (mv < peak_mv - kBatteryChargeEndMv) finished = true;
    const bool now_charging = by_step && !finished;  // a cable alone proves nothing: a finished charger pushes no current
    if (now_charging != battery_charging) {
        battery_charging = now_charging;
        ESP_LOGI(kTag, "Battery: charging %s (%d mV)", now_charging ? "started" : "ended", mv);
        send_sync_status();
    }
    int effective_mv = sorted[n / 2];
    if (battery_charging) {
        const int push = effective_mv <= 3800 ? 150 : (effective_mv >= 4150 ? 80 : 150 - (effective_mv - 3800) * 70 / 350);
        effective_mv -= push;
    }
    // The charger only ends its cycle when the cell is full, whatever the loaded voltage then reads (a board that
    // is awake sags 30 to 40 mV): show 100 until the cable comes out.
    static bool full_hold = false;
    full_hold = by_step && (full_hold || finished);
    int raw = full_hold ? 100 : circuit_battery::percent_from_mv(effective_mv);
    const int shown = battery_percent;
    if (battery_charging && shown >= 0 && raw < shown) raw = shown;
    if (shown >= 0 && (raw - shown < 4 && shown - raw < 4)) return;
    int rounded = ((raw + 2) / 5) * 5;
    if (rounded > 100) rounded = 100;
    if (rounded == shown) return;
    battery_percent = rounded;
    ESP_LOGI(kTag, "Battery now %d%% (%d mV)", rounded, sorted[n / 2]);
    if (update_power_mode(rounded)) apply_power_policy();
    send_sync_status();
}

// While a computer is on the USB cable the board stays awake: it is powered, its console and the programmer both
// need the chip awake, and sleeping saves nothing worth having. A plain charger or a power bank does not count (the
// chip sees no USB frames from them), and the board sleeps as usual: sleeping does not slow charging, which the
// charger does by itself. Checked at each status tick, which wakes the chip about once a second even in sleep.
void update_usb_awake() {
    bool host = usb_serial_jtag_is_connected();
    for (int i = 0; !host && i < 3; ++i) {  // just woken: give the USB frames a moment to show up
        esp_rom_delay_us(2000);
        host = usb_serial_jtag_is_connected();
    }
    if (host == usb_host_connected) return;
    usb_host_connected = host;
    if (usb_awake_lock != nullptr) {
        if (host) esp_pm_lock_acquire(usb_awake_lock);
        else esp_pm_lock_release(usb_awake_lock);
    }
    ESP_LOGW(kTag, "USB host %s: %s", host ? "connected" : "gone", host ? "staying awake" : "sleeping allowed");
}

void sync_ui_tick();

void status_icon_task(void *) {
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(900));
        ++status_icon_frame;
        update_usb_awake();
        battery_tick();
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

// The firmware update screen: a turning cog with the percentage under it. It borrows the sync screen (so
// the usual rules about what may interrupt what still hold) and swaps the artwork for the cog.
void show_update_screen() {
    // One lock through the whole change: the sync picture that show_device_screen() puts up first must never
    // reach the e-paper (it would show for a second before the cog).
    if (!Lvgl_lock(-1)) return;
    show_device_screen(DeviceScreen::Syncing);
    lv_obj_add_flag(wordmark_image, LV_OBJ_FLAG_HIDDEN);
    // The cog needs the middle of the screen: hide the clock and the note counts (the date and the status
    // icons stay). They come back with the next screen (see show_device_screen).
    for (lv_obj_t *label : {idle_time_label, idle_ampm_label, idle_pending_label, idle_done_label, idle_clock_icon,
                            idle_check_icon}) {
        lv_obj_add_flag(label, LV_OBJ_FLAG_HIDDEN);
    }
    update_frame = 0;
    lv_img_set_src(update_cog_obj, circuit_update_frames[0]);
    lv_obj_clear_flag(update_cog_obj, LV_OBJ_FLAG_HIDDEN);
    lv_obj_set_style_text_font(sync_progress_label, &lv_font_montserrat_36, 0);
    lv_obj_set_width(sync_progress_label, 150);
    lv_obj_set_style_text_align(sync_progress_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(sync_progress_label, LV_ALIGN_TOP_MID, 0, 122);
    lv_label_set_text(sync_progress_label, "0%");
    lv_obj_clear_flag(sync_progress_label, LV_OBJ_FLAG_HIDDEN);
    update_screen_active = true;
    ghost_clear_pending = true;  // wipe the traces of the clock once the cog screen has been drawn
    Lvgl_unlock();
}

// Runs in the status icon task, at most once per tick.
void sync_ui_tick() {
    if (ghost_clear_pending) {
        ghost_clear_pending = false;
        epaper_full_refresh();
        return;  // the next tick carries on with the cog
    }
    const int32_t percent = sync_ui_percent;
    if (update_screen_active && percent >= 0 && active_screen == DeviceScreen::Syncing) {
        // The cog turns one step on every redraw, even when the figure has not moved.
        if (Lvgl_lock(-1)) {
            update_frame = (update_frame + 1) % circuit_update_frame_count;
            lv_img_set_src(update_cog_obj, circuit_update_frames[update_frame]);
            char text[16];
            snprintf(text, sizeof(text), "%d%%", static_cast<int>(percent));
            lv_label_set_text(sync_progress_label, text);
            Lvgl_unlock();
        }
        sync_ui_shown = percent;
        return;
    }
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

// Opens a session that takes one upload from the phone: a spoken message (@speak-prepare) or a firmware
// image (@firmware-prepare). The phone asks over the bonded BLE link and gets the same kind of offer as a
// sync, under its own name.
void offer_upload(bool firmware) {
    char ip[16];
    uint16_t port = 0;
    char token[33];
    const char *fingerprint = nullptr;
    uint32_t count = 0, bytes = 0;
    const char *what = firmware ? "Update" : "Broadcast";
    char problem[96];
    if (recording_only()) {
        snprintf(problem, sizeof(problem), "%s failed: battery is low, Circuit only records now", what);
        report_audio_status(problem);
        return;
    }
    if (recording_active || audio_busy || circuit_sync::is_open()) {
        snprintf(problem, sizeof(problem), "%s failed: Circuit is busy", what);
        report_audio_status(problem);
        return;
    }
    if (wifi_resting && wifi_ssid[0] != '\0') {  // switched off to save power: wake it, then come back here
        request_after_wifi(firmware ? AfterWifi::Update : AfterWifi::Broadcast, false);
        return;
    }
    if (!can_offer_wifi_sync() || !circuit_sync::wifi_ip(ip, sizeof(ip))) {
        snprintf(problem, sizeof(problem), "%s needs Wi-Fi: connect Circuit and your phone to the same network", what);
        report_audio_status(problem);
        return;
    }
    if (!circuit_sync::open_session(&port, token, sizeof(token), &fingerprint, &count, &bytes, 0, !firmware, firmware)) {
        snprintf(problem, sizeof(problem), "%s failed: could not open a session", what);
        report_audio_status(problem);
        return;
    }
    if (firmware) {  // an update shows its progress on the sync screen
        circuit_sync::state.on_progress = wifi_sync_progress;
        show_update_screen();
        sync_ui_percent = 0;
        sync_ui_shown = -1;
    }
    char offer[kMaxTextBytes + 40];
    snprintf(offer, sizeof(offer), "%s\n%s\n%u\n%s\n%s", firmware ? "@firmware-offer" : "@speak-offer", ip,
        static_cast<unsigned>(port), token, fingerprint);
    snprintf(last_offer, sizeof(last_offer), "%s", offer);
    last_offer_sent_ms = circuit_sync::now_ms();
    send_relay_request(offer);
    if (sync_supervisor_handle != nullptr) xTaskNotifyGive(sync_supervisor_handle);
    ESP_LOGI(kTag, "%s session offered", what);
}

void offer_speak() { offer_upload(false); }

void flash_sync_result(const char *text);

// Installs the firmware image the phone left on the card (circuit_sync::kFirmwarePath): into the other app
// slot, checked, then booted. The old image stays valid until the very last step, and the bootloader goes
// back to it if the new one does not confirm itself (see mark_firmware_good). Runs on the supervisor task,
// whose stack is in internal RAM, as flash cannot be written from the HTTP server's. Restarts on success.
void install_firmware() {
    firmware_installing = true;
    const char *failure = nullptr;
    FILE *file = fopen(circuit_sync::kFirmwarePath, "rb");
    const esp_partition_t *slot = esp_ota_get_next_update_partition(nullptr);
    auto *buffer = static_cast<uint8_t *>(heap_caps_malloc(4096, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    esp_ota_handle_t handle = 0;
    size_t size = 0;
    if (file != nullptr) {
        fseek(file, 0, SEEK_END);
        size = static_cast<size_t>(ftell(file));
        fseek(file, 0, SEEK_SET);
    }
    if (file == nullptr || slot == nullptr || buffer == nullptr) {
        failure = "Update failed: could not read the new firmware";
    } else if (esp_ota_begin(slot, size, &handle) != ESP_OK) {
        failure = "Update failed: could not prepare the update slot";
    } else {
        size_t done = 0, got = 0;
        int shown = -1;
        while ((got = fread(buffer, 1, 4096, file)) > 0) {
            if (esp_ota_write(handle, buffer, got) != ESP_OK) {
                failure = "Update failed: could not write the new firmware";
                break;
            }
            done += got;
            const int percent = 50 + static_cast<int>(done * 49 / size);  // 100 only once it is in place
            if (percent != shown) {
                shown = percent;
                sync_ui_percent = percent;
            }
        }
        if (failure != nullptr || done != size) {
            if (failure == nullptr) failure = "Update failed: the file was cut short";
            esp_ota_abort(handle);
        } else if (esp_ota_end(handle) != ESP_OK) {
            failure = "Update failed: the new firmware did not check out";
        } else {
            esp_app_desc_t incoming = {};
            const esp_app_desc_t *running = esp_app_get_description();
            if (esp_ota_get_partition_description(slot, &incoming) != ESP_OK ||
                strncmp(incoming.project_name, running->project_name, sizeof(incoming.project_name)) != 0) {
                failure = "Update failed: that file is not Circuit firmware";
            } else if (esp_ota_set_boot_partition(slot) != ESP_OK) {
                failure = "Update failed: could not switch to the new firmware";
            } else {
                ESP_LOGW(kTag, "Firmware %s installed, restarting", incoming.version);
            }
        }
    }
    if (file != nullptr) fclose(file);
    if (buffer != nullptr) heap_caps_free(buffer);
    remove(circuit_sync::kFirmwarePath);
    if (failure != nullptr) {
        firmware_installing = false;
        ESP_LOGW(kTag, "%s", failure);
        sync_ui_percent = -1;
        flash_sync_result("ERR");
        report_audio_status(failure);
        return;
    }
    sync_ui_percent = 100;
    report_audio_status("Update installed: Circuit is restarting");
    vTaskDelay(pdMS_TO_TICKS(1500));  // let the phone hear the answer before the link drops
    esp_restart();
}

// The firmware in the other app slot (the one before the last update), if it is a working Circuit image.
// Fills `version` and the first eight hex digits of its build fingerprint.
bool previous_firmware(char *version, size_t version_size, char *build, size_t build_size) {
    const esp_partition_t *other = esp_ota_get_next_update_partition(nullptr);
    esp_app_desc_t desc = {};
    esp_ota_img_states_t state = ESP_OTA_IMG_UNDEFINED;
    if (other == nullptr || esp_ota_get_partition_description(other, &desc) != ESP_OK ||
        strncmp(desc.project_name, esp_app_get_description()->project_name, sizeof(desc.project_name)) != 0) {
        return false;
    }
    if (esp_ota_get_state_partition(other, &state) == ESP_OK &&
        (state == ESP_OTA_IMG_INVALID || state == ESP_OTA_IMG_ABORTED)) {
        return false;  // the bootloader already found that one failing
    }
    snprintf(version, version_size, "%.31s", desc.version);
    snprintf(build, build_size, "%02x%02x%02x%02x", desc.app_elf_sha256[0], desc.app_elf_sha256[1],
        desc.app_elf_sha256[2], desc.app_elf_sha256[3]);
    return true;
}

// Switches back to the previous firmware: no upload, just the boot choice and a restart.
void revert_firmware_task(void *) {
    char version[32], build[9];
    if (recording_only()) {
        report_audio_status("Update failed: battery is low, Circuit only records now");
    } else if (update_busy() || audio_busy || recording_active || circuit_sync::is_open()) {
        report_audio_status("Update failed: Circuit is busy");
    } else if (!previous_firmware(version, sizeof(version), build, sizeof(build))) {
        report_audio_status("Update failed: there is no previous firmware on Circuit");
    } else if (esp_ota_set_boot_partition(esp_ota_get_next_update_partition(nullptr)) != ESP_OK) {
        report_audio_status("Update failed: could not switch to the previous firmware");
    } else {
        ESP_LOGW(kTag, "Going back to firmware %s (%s), restarting", version, build);
        firmware_installing = true;  // nothing else starts in the next moments
        report_audio_status("Update installed: Circuit is restarting on its previous firmware");
        vTaskDelay(pdMS_TO_TICKS(1500));
        esp_restart();
    }
    vTaskDelete(nullptr);
}

// After an update, the bootloader keeps the new image on probation: it reverts to the old one if the board
// resets before this is called. Called once the board has been up long enough to be trusted.
void mark_firmware_good() {
    esp_ota_img_states_t state = ESP_OTA_IMG_UNDEFINED;
    if (esp_ota_get_state_partition(esp_ota_get_running_partition(), &state) == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY) {
        esp_ota_mark_app_valid_cancel_rollback();
        ESP_LOGW(kTag, "New firmware confirmed");
    }
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
    const bool syncing = circuit_sync::is_open();
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
    show_pending_from_card();
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
    int64_t last_slow_check_ms = 0;
    bool firmware_confirmed = false;
    while (true) {
        // A broadcast or update session is watched twice a second; with none open it sleeps, and offering one
        // wakes it (so an idle board is not woken twice a second for nothing).
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(circuit_sync::is_open() ? 500 : 7500));
        // A new firmware is kept only once it has run for 40 s AND a phone has connected to it (so one that cannot
        // talk to a phone is not kept), or after ten minutes with no phone about, so it is not left on trial forever.
        if (circuit_sync::is_open()) wifi_last_needed_ms = circuit_sync::now_ms();  // checked twice a second then
        const int64_t up_s = esp_timer_get_time() / 1000000;
        if (!firmware_confirmed && up_s > 40 && (ble_seen_since_boot || up_s > 600)) {
            mark_firmware_good();
            firmware_confirmed = true;
        }
        if (circuit_sync::is_open() && circuit_sync::state.speak) {
            // A broadcast session is not a sync: it ends when the message arrives or the phone gives up.
            if (circuit_sync::state.firmware_ready) {
                circuit_sync::close_session();
                install_firmware();
            } else if (circuit_sync::state.speak_ready) {
                circuit_sync::close_session();
                start_speak_playback();
            } else if (circuit_sync::expired() || connection_id == UINT16_MAX) {
                const bool update = circuit_sync::state.firmware;
                circuit_sync::close_session();
                if (update) {
                    sync_ui_percent = -1;
                    flash_sync_result("ERR");
                }
                report_audio_status(update ? "Update failed: the phone did not send the firmware"
                                           : "Broadcast failed: the phone did not send the message");
            } else if (circuit_sync::state.client_ip == 0 && ble_encrypted &&
                       circuit_sync::now_ms() - last_offer_sent_ms > kOfferResendMs) {
                last_offer_sent_ms = circuit_sync::now_ms();
                send_relay_request(last_offer);
            }
            continue;
        }
        if (circuit_sync::now_ms() - last_slow_check_ms < pdTICKS_TO_MS(kSyncSupervisorInterval) - 600) continue;
        last_slow_check_ms = circuit_sync::now_ms();
        // Once the radios are up (not at the very start), put the Bluetooth rhythm that goes with the power mode in place.
        static bool policy_applied = false;
        if (!policy_applied && esp_timer_get_time() > 10LL * 1000000) {
            policy_applied = true;
            apply_power_policy();
        }
        // Wi-Fi follows the power mode: resting below Saver once it has sat unused for a minute, back on in Saver.
        if (circuit_sync::is_open() || after_wifi != AfterWifi::Nothing) wifi_last_needed_ms = circuit_sync::now_ms();
        if (effective_power_mode() != PowerMode::Saver) {
            if (!wifi_resting && circuit_sync::now_ms() - wifi_last_needed_ms > kWifiIdleBeforeRestMs) wifi_rest();
        } else if (wifi_resting) {
            wifi_wake();
        }
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

// Notes sync over Wi-Fi only. `forced` is the device button: with no Wi-Fi sync possible it shows the failure
// on the device's own screen; the app is told in a status message.
// `only_recording` (the app's "sync this note") limits the sync to that recording; 0 syncs everything.
void start_audio_sync(bool forced, uint32_t only_recording = 0) {
    if (recording_only()) {
        report_audio_status("Battery is low: Circuit only records now. Charge it to sync");
        if (forced) flash_sync_result("LOW");
        return;
    }
    if (update_busy()) {
        report_audio_status("Cannot sync while Circuit is updating");
        return;
    }
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
    if (wifi_resting && wifi_ssid[0] != '\0') {  // switched off to save power: wake it, then come back here
        request_after_wifi(AfterWifi::Sync, forced);
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
    // Notes move over Wi-Fi only: Bluetooth is for control and status, not for files.
    update_storage_status("Sync needs Wi-Fi\nCircuit and phone");
    report_audio_status("Sync needs Wi-Fi: connect Circuit and your phone to the same network");
    if (forced) flash_sync_result("ERR");
}

void start_playback();
void lower_key_released(uint32_t held_ms);
#ifdef CIRCUIT_DEV_CONSOLE
std::atomic<int> dev_drop_link_ms{-1};  // see dev_drop_link_task: cut the next link this many ms after it connects
std::atomic<bool> dev_key_down{false};  // the development console "presses" the key through this

// Lower key (GPIO18) state for the development console: what the real key task below has seen.
constexpr gpio_num_t kLowerKeyPin = GPIO_NUM_18;
constexpr gpio_num_t kPowerLatchPin = GPIO_NUM_17;
std::atomic<uint32_t> lower_key_presses{0};
std::atomic<uint32_t> lower_key_longest_ms{0};
// Development console (built only with -DCIRCUIT_DEV_CONSOLE=1, see tools/board_dev.py). Reads one-line
// commands from the USB port: "copy N", "copy-sync N", "sync", "status". It exists to test sync without
// recording by hand: "copy" makes N new unsynced notes from the newest synced single-part notes.
// "copy-last": a real, playable copy of the newest recording (every part of it) as new, unsynced notes.
// The note number is part of the encryption, so each part is opened and sealed again under its new
// number; the Moments and the grouping into parts are carried over. Returns how many parts it copied.
int dev_copy_last() {
    const uint32_t newest = circuit_notes::newest_id();
    if (newest == 0 || !note_key_ready) return 0;
    const uint32_t first_old = circuit_notes::recording_of(newest);
    auto *reader = new (std::nothrow) circuit_secure::Reader();
    auto *writer = new (std::nothrow) circuit_secure::Writer();
    uint8_t *chunk = static_cast<uint8_t *>(heap_caps_malloc(circuit_secure::kChunkBytes, MALLOC_CAP_SPIRAM));
    int copied = 0;
    uint32_t first_new = 0;
    for (uint32_t old_id = first_old; reader && writer && chunk && old_id <= newest; ++old_id) {
        circuit_notes::Note note;
        if (!circuit_notes::describe(old_id, &note) || !note.encrypted) continue;
        char from[48], to[48];
        circuit_notes::path_for(old_id, "ENC", from, sizeof(from));
        const uint32_t new_id = circuit_notes::allocate_id();
        circuit_notes::path_for(new_id, "ENC", to, sizeof(to));
        bool ok = reader->open(from) &&
                  writer->open(to, note_key, new_id, kAudioSampleRate, kAudioChannels, kAudioBitsPerSample);
        size_t bytes = 0;
        while (ok) {
            const size_t n = reader->read(chunk);
            if (n == 0) break;
            ok = writer->append(chunk, n);
            bytes += n;
        }
        reader->close();
        ok = ok && writer->finish() && bytes > 0;
        if (!ok) {
            writer->abort();
            remove(to);
            ESP_LOGW(kTag, "DEV copy-last: part %lu could not be copied", static_cast<unsigned long>(old_id));
            break;
        }
        if (first_new == 0) first_new = new_id;
        circuit_notes::Group group;
        if (circuit_notes::read_group(old_id, &group)) {
            circuit_notes::write_group(new_id, {first_new, group.part, group.final});
        }
        uint32_t offsets[circuit_moments::kMaxPerPart];
        const size_t count = circuit_moments::load(old_id, note_key, offsets, circuit_moments::kMaxPerPart);
        if (count > 0) circuit_moments::save(new_id, note_key, offsets, count);
        ESP_LOGW(kTag, "DEV copy-last: note %lu -> %lu (%u bytes of audio, %u moments)", static_cast<unsigned long>(old_id),
            static_cast<unsigned long>(new_id), static_cast<unsigned>(bytes), static_cast<unsigned>(count));
        ++copied;
    }
    delete reader;
    delete writer;
    if (chunk != nullptr) heap_caps_free(chunk);
    ESP_LOGW(kTag, "DEV copy-last done: %d part(s) copied, %u waiting", copied, static_cast<unsigned>(circuit_notes::count_unsynced()));
    return copied;
}

int dev_copy_notes(int wanted) {
    uint32_t sources[8] = {};
    int found = 0;
    if (wanted > 8) wanted = 8;
    for (uint32_t id = circuit_notes::newest_id(); id > 0 && found < wanted; --id) {
        circuit_notes::Note note;
        circuit_notes::Group group;
        if (circuit_notes::describe(id, &note) && note.synced && note.encrypted &&
            !circuit_notes::read_group(id, &group) && note.bytes > 200000) {
            sources[found++] = id;
        }
    }
    uint8_t *buffer = static_cast<uint8_t *>(heap_caps_malloc(4096, MALLOC_CAP_SPIRAM));
    int copied = 0;
    for (int i = 0; i < found && buffer != nullptr; ++i) {
        char from[48], to[48];
        circuit_notes::path_for(sources[i], "ENC", from, sizeof(from));
        const uint32_t id = circuit_notes::allocate_id();
        circuit_notes::path_for(id, "ENC", to, sizeof(to));
        FILE *in = fopen(from, "rb");
        FILE *out = fopen(to, "wb");
        size_t n = 0, total = 0;
        while (in != nullptr && out != nullptr && (n = fread(buffer, 1, 4096, in)) > 0) {
            fwrite(buffer, 1, n, out);
            total += n;
        }
        if (in != nullptr) fclose(in);
        if (out != nullptr) fclose(out);
        ESP_LOGW(kTag, "DEV copied note %lu to %lu (%u bytes)", static_cast<unsigned long>(sources[i]),
            static_cast<unsigned long>(id), static_cast<unsigned>(total));
        ++copied;
    }
    if (buffer != nullptr) heap_caps_free(buffer);
    ESP_LOGW(kTag, "DEV copy done: %d note(s) copied, %u waiting", copied,
        static_cast<unsigned>(circuit_notes::count_unsynced()));
    return copied;
}

// Asks for a sync the way the phone does (so playback gives way to it). It does not wait for the sync
// to end: a task kept alive for that would hold its stack, internal RAM a sync needs. The sync's own
// "SYNCSTAT" log line says when it is over.
void dev_sync_and_wait() {
    for (int i = 0; i < 240 && !(ble_encrypted && connection_id != UINT16_MAX); ++i) vTaskDelay(pdMS_TO_TICKS(500));
    start_audio_sync(false);
    ESP_LOGW(kTag, "DEV sync requested");
}

// The console must stay responsive during a sync (to test pressing the key meanwhile), so a sync
// waits in a task of its own.
void dev_sync_task(void *) {
    dev_sync_and_wait();
    vTaskDelete(nullptr);
}

void dev_console_task(void *) {
    usb_serial_jtag_driver_config_t config = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    config.rx_buffer_size = 256;
    config.tx_buffer_size = 256;
    usb_serial_jtag_driver_install(&config);
    ESP_LOGW(kTag, "DEV console ready");
    char line[48];
    size_t used = 0;
    while (true) {
        uint8_t c;
        if (usb_serial_jtag_read_bytes(&c, 1, pdMS_TO_TICKS(200)) <= 0) continue;
        if (c != '\r' && c != '\n') {
            if (used < sizeof(line) - 1) line[used++] = static_cast<char>(c);
            continue;
        }
        line[used] = '\0';
        used = 0;
        int n = 3;
        if (strncmp(line, "copy-sync", 9) == 0) {
            if (sscanf(line + 9, "%d", &n) != 1) n = 3;
            dev_copy_notes(n);
            xTaskCreate(dev_sync_task, "dev_sync", 6144, nullptr, 4, nullptr);
        } else if (strcmp(line, "copy-last") == 0) {
            dev_copy_last();
        } else if (strncmp(line, "copy", 4) == 0) {
            if (sscanf(line + 4, "%d", &n) != 1) n = 3;
            dev_copy_notes(n);
        } else if (strcmp(line, "resend") == 0) {
            ESP_LOGW(kTag, "DEV marked %u note(s) to be sent again",
                static_cast<unsigned>(circuit_notes::mark_all_unsynced()));
            xTaskCreate(dev_sync_task, "dev_sync", 6144, nullptr, 4, nullptr);
        } else if (strncmp(line, "drop-next-link", 14) == 0) {
            int ms = 100;
            if (sscanf(line + 14, "%d", &ms) != 1) ms = 100;
            dev_drop_link_ms = ms;
            ESP_LOGW(kTag, "DEV drop-next-link armed: %d ms after the next connect", ms);
        } else if (strncmp(line, "battery-set ", 12) == 0) {
            // Pretends the charge is N% until the next real reading (about a minute): for checking the LOW
            // header and the phone's low-battery alert without draining the cell.
            battery_percent = atoi(line + 12);
            if (update_power_mode(battery_percent)) apply_power_policy();
            refresh_status_icons();
            send_sync_status();
            ESP_LOGW(kTag, "DEV battery-set: showing %d%%, power mode %s", static_cast<int>(battery_percent),
                power_mode_name(effective_power_mode()));
        } else if (strncmp(line, "sleep", 5) == 0) {
            if (strcmp(line, "sleep on") == 0) set_light_sleep(true);
            else if (strcmp(line, "sleep off") == 0) {
                light_sleep_pinned_off = true;  // and not turned on again by the start-up timer
                set_light_sleep(false);
            }
            ESP_LOGW(kTag, "DEV sleep: light sleep is %s", light_sleep_on ? "on" : "off");
        } else if (strcmp(line, "pm") == 0) {
            log_power_use();
            ESP_LOGW(kTag, "DEV pm: light sleep is %s", light_sleep_on ? "on" : "off");
        } else if (strncmp(line, "update-screen", 13) == 0) {
            // Shows the update screen at N% for a minute, without updating anything.
            show_update_screen();
            sync_ui_percent = line[13] == ' ' ? atoi(line + 14) : 50;
            sync_ui_shown = -1;
            return_to_idle_after(DeviceScreen::Syncing, 60000);
            ESP_LOGW(kTag, "DEV update-screen: shown at %d%% for a minute", static_cast<int>(sync_ui_percent));
        } else if (strcmp(line, "firmware-open") == 0) {
            offer_upload(true);
            char offer[sizeof(last_offer)];
            snprintf(offer, sizeof(offer), "%s", last_offer);
            for (char *c = offer; *c != '\0'; ++c) if (*c == '\n') *c = ' ';
            ESP_LOGW(kTag, "DEV firmware-open: %s", offer);
        } else if (strcmp(line, "speak-open") == 0) {
            offer_speak();
            char offer[sizeof(last_offer)];
            snprintf(offer, sizeof(offer), "%s", last_offer);
            for (char *c = offer; *c != '\0'; ++c) if (*c == '\n') *c = ' ';
            ESP_LOGW(kTag, "DEV speak-open: %s", offer);
        } else if (strcmp(line, "drop-now") == 0) {
            ESP_LOGW(kTag, "DEV drop-now: cutting the current link");
            esp_ble_gap_disconnect(peer_bda);
        } else if (strcmp(line, "sync") == 0) {
            xTaskCreate(dev_sync_task, "dev_sync", 6144, nullptr, 4, nullptr);
        } else if (strncmp(line, "rec", 3) == 0 && strncmp(line, "rec-", 4) != 0) {
            // "rec [seconds]": record without the key (default: until stopped)
            unsigned long seconds = kMaxRecordingSeconds;
            if (sscanf(line + 3, "%lu", &seconds) != 1) seconds = kMaxRecordingSeconds;
            char command[32];
            snprintf(command, sizeof(command), "@audio-record\n%lu", seconds);
            start_recording(command);
            ESP_LOGW(kTag, "DEV record requested (%lu s)", seconds);
        } else if (strcmp(line, "rec-stop") == 0) {
            stop_recording();
            ESP_LOGW(kTag, "DEV stop requested");
        } else if (strcmp(line, "rec-pause") == 0) {
            toggle_pause_recording();
            ESP_LOGW(kTag, "DEV pause toggled");
        } else if (strcmp(line, "play") == 0) {
            start_playback();
            ESP_LOGW(kTag, "DEV play requested");
        } else if (strcmp(line, "play-stop") == 0) {
            if (playback_active.load()) playback_stop_requested = true;
            ESP_LOGW(kTag, "DEV play-stop requested");
        } else if (strncmp(line, "key ", 4) == 0) {
            // "key tap" or "key hold <seconds>": press the real key, so its own rules apply
            float seconds = 0.12f;
            if (strncmp(line + 4, "hold", 4) == 0 && sscanf(line + 8, "%f", &seconds) != 1) seconds = 1.2f;
            dev_key_down = true;
            if (record_button_handle != nullptr) xTaskNotifyGive(record_button_handle);
            vTaskDelay(pdMS_TO_TICKS(static_cast<uint32_t>(seconds * 1000)));
            dev_key_down = false;
            if (record_button_handle != nullptr) xTaskNotifyGive(record_button_handle);
            ESP_LOGW(kTag, "DEV key pressed for %.2f s", seconds);
        } else if (strncmp(line, "delete ", 7) == 0) {
            const unsigned long id = strtoul(line + 7, nullptr, 10);
            if (id == 0 || audio_busy || recording_active || circuit_sync::is_open()) {
                ESP_LOGW(kTag, "DEV delete refused (busy or no number)");
            } else {
                ESP_LOGW(kTag, "DEV deleted note %lu: %s", id,
                    circuit_notes::remove_note(static_cast<uint32_t>(id)) ? "removed" : "was already gone");
                show_pending_from_card();
            }
        } else if (strcmp(line, "list") == 0) {
            for (uint32_t id = circuit_notes::newest_id(); id > 0 && id + 12 > circuit_notes::newest_id(); --id) {
                circuit_notes::Note note;
                if (circuit_notes::describe(id, &note)) {
                    ESP_LOGW(kTag, "DEV note %lu: %lu bytes, %s", static_cast<unsigned long>(id),
                        static_cast<unsigned long>(note.bytes), note.synced ? "synced" : "waiting");
                }
            }
            ESP_LOGW(kTag, "DEV list done");
        } else if (strncmp(line, "logtail", 7) == 0) {
            // "logtail [KB]": the end of the log kept on the card, printed to the serial port
            unsigned kb = 8, index = 0;
            if (sscanf(line + 7, "%u %u", &kb, &index) < 1 || kb == 0) kb = 8;
            char log_path[40];
            snprintf(log_path, sizeof(log_path), "/sdcard/LOGS/CIRCUIT%u.LOG", index > 3 ? 0 : index);
            FILE *file = fopen(log_path, "rb");
            if (file == nullptr) {
                printf("SDLOG| no log file on the card\n");
            } else {
                fseek(file, 0, SEEK_END);
                long size = ftell(file);
                long from = size > static_cast<long>(kb) * 1024 ? size - static_cast<long>(kb) * 1024 : 0;
                fseek(file, from, SEEK_SET);
                char text[160];
                if (from > 0) fgets(text, sizeof(text), file);  // skip the cut first line
                while (fgets(text, sizeof(text), file) != nullptr) {
                    text[strcspn(text, "\r\n")] = '\0';
                    printf("SDLOG| %s\n", text);
                }
                fclose(file);
                printf("SDLOG| end (file is %ld bytes)\n", size);
            }
        } else if (strcmp(line, "crash") == 0) {
            // Like a power cut: nothing gets to finish or close its files.
            ESP_LOGW(kTag, "DEV crash requested");
            vTaskDelay(pdMS_TO_TICKS(200));
            esp_restart();
        } else if (strcmp(line, "rtc") == 0) {
            time_t chip = 0;
            const bool chip_ok = circuit_rtc::read(&chip, kMinValidEpoch);
            const time_t now = time(nullptr);
            ESP_LOGW(kTag, "DEV rtc: chip=%s %lld, system=%lld, difference=%lld s, clock_set=%d",
                chip_ok ? "valid" : "invalid", static_cast<long long>(chip), static_cast<long long>(now),
                static_cast<long long>(now - chip), clock_set ? 1 : 0);
        } else if (strncmp(line, "clock-skew ", 11) == 0) {
            // Moves the system clock by N seconds (the RTC chip is left alone): the phone must put it right.
            timeval tv = {};
            gettimeofday(&tv, nullptr);
            tv.tv_sec += atoi(line + 11);
            settimeofday(&tv, nullptr);
            ESP_LOGW(kTag, "DEV clock-skew: system clock moved by %d s", atoi(line + 11));
        } else if (strcmp(line, "rtc-lose") == 0) {
            // Like a power cut for the clock: forget the system time (the chip keeps its own), then restart.
            timeval tv = {.tv_sec = 100, .tv_usec = 0};
            settimeofday(&tv, nullptr);
            ESP_LOGW(kTag, "DEV rtc-lose: system clock wiped, restarting");
            vTaskDelay(pdMS_TO_TICKS(300));
            esp_restart();
        } else if (strncmp(line, "lower-tap", 9) == 0) {
            // "lower-tap" (a short press) or "lower-tap hold <seconds>": a finished press of that length
            float seconds = 0.12f;
            if (strncmp(line + 9, " hold", 5) == 0 && sscanf(line + 14, "%f", &seconds) != 1) seconds = 1.2f;
            lower_key_released(static_cast<uint32_t>(seconds * 1000));
            ESP_LOGW(kTag, "DEV lower key pressed for %.2f s", seconds);
            // What the cue shows 1.3 s after the press (the screen redraws about every 0.7 s), read on the
            // board so the test does not depend on how quickly the computer asks.
            vTaskDelay(pdMS_TO_TICKS(1300));
            char number[12] = "";
            bool hidden = true;
            if (Lvgl_lock(1000)) {
                snprintf(number, sizeof(number), "%s", lv_label_get_text(recording_moment_count));
                hidden = lv_obj_has_flag(recording_moment_icon, LV_OBJ_FLAG_HIDDEN);
                Lvgl_unlock();
            }
            ESP_LOGW(kTag, "DEV cue-after-tap: screen=%d icon_hidden=%d number='%s' count=%u", static_cast<int>(active_screen),
                hidden ? 1 : 0, number, static_cast<unsigned>(recording_moments.load()));
        } else if (strcmp(line, "cue") == 0) {
            // What the recording screen's Moment cue shows right now: the bookmark and the number beside it
            char number[12] = "";
            bool hidden = true;
            if (Lvgl_lock(1000)) {
                snprintf(number, sizeof(number), "%s", lv_label_get_text(recording_moment_count));
                hidden = lv_obj_has_flag(recording_moment_icon, LV_OBJ_FLAG_HIDDEN);
                Lvgl_unlock();
            }
            ESP_LOGW(kTag, "DEV cue: screen=%d icon_hidden=%d number='%s' count=%u", static_cast<int>(active_screen),
                hidden ? 1 : 0, number, static_cast<unsigned>(recording_moments.load()));
        } else if (strcmp(line, "moments-selftest") == 0) {
            ESP_LOGW(kTag, "DEV moments-selftest: %s", circuit_moments::selftest() ? "PASS" : "FAIL");
        } else if (strncmp(line, "moments ", 8) == 0) {
            // "moments ID": read and open the moments file of note ID
            const unsigned long id = strtoul(line + 8, nullptr, 10);
            uint32_t offsets[circuit_moments::kMaxPerPart];
            const size_t count = id == 0 || !note_key_ready ? 0 : circuit_moments::load(static_cast<uint32_t>(id), note_key, offsets, circuit_moments::kMaxPerPart);
            char line_text[160] = {};
            size_t used = 0;
            for (size_t i = 0; i < count && used + 12 < sizeof(line_text); ++i) {
                used += snprintf(line_text + used, sizeof(line_text) - used, "%lu ", static_cast<unsigned long>(offsets[i]));
            }
            ESP_LOGW(kTag, "DEV moments of note %lu: %u: %s", id, static_cast<unsigned>(count), line_text);
        } else if (strcmp(line, "lower") == 0) {
            ESP_LOGW(kTag, "DEV lower: GPIO18 level=%d (0 = pressed), GPIO17 level=%d, presses=%u, longest=%u ms, held now=%d",
                gpio_get_level(kLowerKeyPin), gpio_get_level(kPowerLatchPin),
                static_cast<unsigned>(lower_key_presses.load()), static_cast<unsigned>(lower_key_longest_ms.load()),
                0);
        } else if (strcmp(line, "battery") == 0) {
            int raw = 0;
            const int mv = circuit_battery::read_mv(&raw);
            if (mv > 0) {
                ESP_LOGW(kTag, "DEV battery: %d mV, about %d%% (raw %d)", mv, circuit_battery::percent_from_mv(mv), raw);
            } else {
                ESP_LOGW(kTag, "DEV battery: not readable");
            }
        } else if (strcmp(line, "status") == 0) {
            circuit_sync::log_heap("dev status");
            if (Lvgl_lock(1000)) {
                lv_mem_monitor_t mon;
                lv_mem_monitor(&mon);
                Lvgl_unlock();
                ESP_LOGW(kTag, "DEV lvgl pool: total %u, free %u, highest ever used %u (%u%%)",
                    static_cast<unsigned>(mon.total_size), static_cast<unsigned>(mon.free_size),
                    static_cast<unsigned>(mon.max_used), static_cast<unsigned>(mon.max_used * 100u / mon.total_size));
            }
            ESP_LOGW(kTag, "DEV status: version=%s waiting=%u recording=%d paused=%d playing=%d sync_open=%d tasks=%u",
                esp_app_get_description()->version, static_cast<unsigned>(circuit_notes::count_unsynced()), recording_active ? 1 : 0,
                recording_paused ? 1 : 0, playback_active.load() ? 1 : 0, circuit_sync::is_open() ? 1 : 0,
                static_cast<unsigned>(uxTaskGetNumberOfTasks()));
        } else if (line[0] != '\0') {
            ESP_LOGW(kTag, "DEV unknown command '%s' (copy N, copy-sync N, sync, status)", line);
        }
    }
}
#endif

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
// The record key's edges wake its task, which otherwise sleeps: polling it 50 times a second would keep the
// processor from ever sleeping.
void IRAM_ATTR record_button_isr(void *) {
    BaseType_t woken = pdFALSE;
    if (record_button_handle != nullptr) vTaskNotifyGiveFromISR(record_button_handle, &woken);
    if (woken == pdTRUE) portYIELD_FROM_ISR();
}

void record_button_task(void *) {
    // GPIO0 is active-low. Waiting for a released state avoids treating a
    // button held during boot as an unintended request.
    bool was_pressed = gpio_get_level(kRecordButtonPin) == 0;
    TickType_t pressed_at = 0;
    bool hold_handled = false;
    while (true) {
        bool is_pressed = gpio_get_level(kRecordButtonPin) == 0;
#ifdef CIRCUIT_DEV_CONSOLE
        if (dev_key_down.load()) is_pressed = true;
#endif
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
        if (is_pressed) {
            vTaskDelay(kButtonPollInterval);  // held: keep timing it
        } else {
            ulTaskNotifyTake(pdTRUE, portMAX_DELAY);  // idle: sleep until the key changes
        }
    }
}

// The lower key. Only a short press during a recording means anything so far: it adds a Moment.
// (It is read as an ordinary input; this board does not cut the power when it is held on USB.)
//
// A key interrupt timestamps the press and the release, because a polling task cannot be trusted
// here: while the e-paper refreshes (about every 0.7 s during a recording) low-priority tasks stand
// still for hundreds of milliseconds, so a quick tap could be missed, or look like a long press.
// The interrupt only measures; the task below acts on each finished press.
QueueHandle_t lower_key_events = nullptr;   // each finished press, as its length in ms
volatile int64_t lower_down_us = 0;         // when the key went down (0 = up); written by the interrupt
volatile int64_t lower_last_edge_us = 0;

void IRAM_ATTR lower_key_isr(void *) {
    const int64_t now = esp_timer_get_time();
    if (now - lower_last_edge_us < 15000) return;  // contact bounce
    lower_last_edge_us = now;
    if (gpio_get_level(kLowerKeyPin) == 0) {
        lower_down_us = now;
    } else if (lower_down_us != 0) {  // a key held while booting has no recorded press: ignored
        const uint32_t held_ms = static_cast<uint32_t>((now - lower_down_us) / 1000);
        lower_down_us = 0;
        BaseType_t woken = pdFALSE;
        xQueueSendFromISR(lower_key_events, &held_ms, &woken);
        if (woken) portYIELD_FROM_ISR();
    }
}

// Switches the board off when it runs on the battery. The e-paper keeps its picture without power, so
// the message shown here stays on the screen and tells the person the board is off, not just stuck.
//  On USB the board stays powered, so it restarts
// instead of being left stuck on a message.
void power_off(const char *message) {
    ESP_LOGW(kTag, "Powering off: %s", message);
    if (Lvgl_lock(1000)) {
        // A clean screen with just the message, so it reads as "off" and not as a stuck home screen.
        lv_obj_add_flag(wordmark_image, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(message_label, message);
        lv_obj_set_style_text_align(message_label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_align(message_label, LV_ALIGN_CENTER, 0, 20);
        lv_obj_clear_flag(message_label, LV_OBJ_FLAG_HIDDEN);
        lv_obj_move_foreground(message_label);
        Lvgl_unlock();
    }
    vTaskDelay(pdMS_TO_TICKS(3500));  // the e-paper needs a moment to draw it
    gpio_set_level(kBatteryLatchPin, 0);
    vTaskDelay(pdMS_TO_TICKS(2000));
    esp_restart();  // still alive: USB is powering the board
}

// What a finished press of the lower key means. The development console calls it with a length of
// its own, so the same rules run for a test as for a finger.
void lower_key_released(uint32_t held_ms) {
#ifdef CIRCUIT_DEV_CONSOLE
    lower_key_presses++;
    if (held_ms > lower_key_longest_ms.load()) lower_key_longest_ms = held_ms;
    ESP_LOGW(kTag, "DEV lower key pressed for %u ms", static_cast<unsigned>(held_ms));
#endif
    if (held_ms >= kPowerOffHoldMs && !recording_active && active_screen != DeviceScreen::Syncing &&
        !playback_active.load() && !update_busy()) {
        power_off("Off\nHold the power key\nto turn on");
        return;
    }
    if (held_ms <= kLowerTapMaxMs && recording_active && !recording_paused) {
        moment_requests++;
        const uint32_t taken = recording_moments.fetch_add(1) + 1;
        moment_cue_until_ms = esp_timer_get_time() / 1000 + kMomentCueMs;
        ESP_LOGI(kTag, "Lower key tap: Moment requested (%u so far)", static_cast<unsigned>(taken));
    }
}

void lower_key_task(void *) {
    uint32_t held_ms = 0;
    while (true) {
        if (xQueueReceive(lower_key_events, &held_ms, portMAX_DELAY) == pdTRUE) lower_key_released(held_ms);
    }
}

void init_record_button() {
    gpio_config_t config = {
        .pin_bit_mask = 1ULL << kRecordButtonPin,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_ANYEDGE,
    };
    ESP_ERROR_CHECK(gpio_config(&config));
    xTaskCreate(record_button_task, "record_button", 3072, nullptr, 3, &record_button_handle);
    gpio_config_t lower_config = config;
    lower_config.pin_bit_mask = 1ULL << kLowerKeyPin;
    lower_config.intr_type = GPIO_INTR_ANYEDGE;
    ESP_ERROR_CHECK(gpio_config(&lower_config));
    lower_key_events = xQueueCreate(8, sizeof(uint32_t));
    xTaskCreate(lower_key_task, "lower_key", 3072, nullptr, 3, nullptr);
    const esp_err_t isr_service = gpio_install_isr_service(0);  // another part may have installed it already
    if (isr_service != ESP_OK && isr_service != ESP_ERR_INVALID_STATE) ESP_ERROR_CHECK(isr_service);
    ESP_ERROR_CHECK(gpio_isr_handler_add(kLowerKeyPin, lower_key_isr, nullptr));
    ESP_ERROR_CHECK(gpio_isr_handler_add(kRecordButtonPin, record_button_isr, nullptr));
}

// ---- Light sleep -----------------------------------------------------------
// With power management on, the processor sleeps whenever every task is waiting and nothing is due soon, and
// Wi-Fi and Bluetooth wake it only for their own events. A key press cannot wake a sleeping chip as an edge, so
// just before each sleep the two keys are armed as wake-up sources (as levels), and just after it they go back
// to their normal edge interrupts and a press that woke the chip is handed to the key code.
#ifdef CIRCUIT_LIGHT_SLEEP
constexpr bool kLightSleepDefault = true;
#elif defined(CIRCUIT_DEV_CONSOLE)
constexpr bool kLightSleepDefault = false;  // the USB console drops out whenever the chip sleeps
#else
constexpr bool kLightSleepDefault = true;
#endif

esp_err_t keys_enter_light_sleep(int64_t, void *) {
    gpio_wakeup_enable(kRecordButtonPin, GPIO_INTR_LOW_LEVEL);
    gpio_wakeup_enable(kLowerKeyPin, GPIO_INTR_LOW_LEVEL);
    esp_sleep_enable_gpio_wakeup();
    return ESP_OK;
}

esp_err_t keys_exit_light_sleep(int64_t, void *) {
    for (const gpio_num_t pin : {kRecordButtonPin, kLowerKeyPin}) {
        gpio_wakeup_disable(pin);
        gpio_set_intr_type(pin, GPIO_INTR_ANYEDGE);
        gpio_intr_enable(pin);
    }
    // The press that woke the chip was a level, not an edge, so the interrupts never saw it.
    const int64_t now = esp_timer_get_time();
    if (gpio_get_level(kLowerKeyPin) == 0 && lower_down_us == 0) {
        lower_down_us = now;
        lower_last_edge_us = now;
    }
    if (gpio_get_level(kRecordButtonPin) == 0 && record_button_handle != nullptr) xTaskNotifyGive(record_button_handle);
    return ESP_OK;
}

void set_light_sleep(bool on) {
    esp_pm_config_t config = {};
    config.max_freq_mhz = 160;
    config.min_freq_mhz = 80;  // the octal PSRAM and the Wi-Fi/Bluetooth radios are happy down to here
    config.light_sleep_enable = on;
    const esp_err_t result = esp_pm_configure(&config);
    if (result == ESP_OK) light_sleep_on = on;
    ESP_LOGW(kTag, "Light sleep %s: %s", on ? "on" : "off", esp_err_to_name(result));
}

#ifdef CIRCUIT_DEV_CONSOLE
// A development build with sleep on starts with it off for 90 s, so a cable can still be used to read the card's
// log or to flash it after a restart (the USB port is dead while the chip sleeps).
void light_sleep_after_grace(void *) {
    if (!light_sleep_pinned_off) set_light_sleep(true);
}
#endif

void init_light_sleep() {
    esp_pm_sleep_cbs_register_config_t callbacks = {};
    callbacks.enter_cb = keys_enter_light_sleep;
    callbacks.exit_cb = keys_exit_light_sleep;
    ESP_ERROR_CHECK_WITHOUT_ABORT(esp_pm_light_sleep_register_cbs(&callbacks));
    // With power management on, ESP-IDF disables every GPIO pad while the chip sleeps (PM_SLP_DISABLE_GPIO, which
    // saves 200 to 300 uA). That let go of the battery latch: on USB nothing showed, but unplugged the board
    // switched itself off a minute after sleep began. These three pads keep their normal state through a sleep:
    // the battery latch, and the e-paper and audio power rails (dropping those would lose the codec's set-up).
    ESP_ERROR_CHECK_WITHOUT_ABORT(esp_pm_lock_create(ESP_PM_NO_LIGHT_SLEEP, 0, "usb_host", &usb_awake_lock));
    gpio_sleep_sel_dis(kBatteryLatchPin);
    gpio_sleep_sel_dis(GPIO_NUM_6);   // the e-paper's power (EPD_PWR_PIN in Waveshare's epaper_config.h)
    gpio_sleep_sel_dis(GPIO_NUM_42);  // the audio codec and amplifier's power (Audio_PWR_PIN)
#ifdef CIRCUIT_DEV_CONSOLE
    if (kLightSleepDefault) {
        set_light_sleep(false);
        static esp_timer_handle_t grace_timer = nullptr;
        esp_timer_create_args_t args = {};
        args.callback = light_sleep_after_grace;
        args.name = "sleep_grace";
        if (esp_timer_create(&args, &grace_timer) == ESP_OK) esp_timer_start_once(grace_timer, 90LL * 1000000);
        return;
    }
#endif
    set_light_sleep(kLightSleepDefault);
}

// The power manager's table (time spent at each speed and asleep, and what is holding the chip awake), to the
// log on the card, so a day on the battery can be read back afterwards.
void log_power_use() {
    char *text = nullptr;
    size_t size = 0;
    FILE *stream = open_memstream(&text, &size);
    if (stream == nullptr) return;
    esp_pm_dump_locks(stream);
    fclose(stream);
    if (text != nullptr) {
        for (char *line = strtok(text, "\n"); line != nullptr; line = strtok(nullptr, "\n")) {
            ESP_LOGI(kTag, "PM| %s", line);
        }
        free(text);
    }
}

void start_playback() {
    if (recording_only()) {
        report_audio_status("Battery is low: Circuit only records now");
        return;
    }
    if (update_busy()) {
        report_audio_status("Cannot play while Circuit is updating");
        return;
    }
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
        release_audio();
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
    circuit_rtc::write(time(nullptr));
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
    if (wifi_resting) {  // setting up a network needs the radio on
        wifi_resting = false;
        esp_wifi_start();
    }
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
    if (wifi_resting) {
        wifi_resting = false;
        esp_wifi_start();
    }
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
    if (wifi_resting) {  // scanning needs the radio on
        wifi_resting = false;
        esp_wifi_start();
        vTaskDelay(pdMS_TO_TICKS(500));
    }
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
                    show_pending_from_card();  // it may have been one of the waiting ones
                    snprintf(result, sizeof(result), "Note deleted #%lu", id);
                }
                report_audio_status(result);
            } else if (strcmp(message.value, "@notes-resend") == 0) {
                if (audio_busy || recording_active || circuit_sync::is_open()) {
                    report_audio_status("Cannot resend notes while recording or syncing");
                } else {
                    const size_t marked = circuit_notes::mark_all_unsynced();
                    ESP_LOGI(kTag, "Marked %u note(s) to be sent again", static_cast<unsigned>(marked));
                    show_pending_from_card();
                    start_audio_sync(false);
                }
            } else if (strcmp(message.value, "@notes-clean") == 0) {
                if (audio_busy || recording_active || circuit_sync::is_open()) {
                    report_audio_status("Cannot clean notes while recording or syncing");
                } else {
                    const size_t removed = circuit_notes::clean_synced();
                    show_pending_from_card();
                    ESP_LOGI(kTag, "Cleaned %u synced note(s)", static_cast<unsigned>(removed));
                    char result[64];
                    snprintf(result, sizeof(result), "Notes cleaned: %u removed from Circuit", static_cast<unsigned>(removed));
                    report_audio_status(result);
                }
            } else if (strncmp(message.value, "@power-mode\n", 12) == 0) {
                const char *want = message.value + 12;
                const PowerChoice before = power_choice;
                if (strcmp(want, "auto") == 0) power_choice = PowerChoice::Auto;
                else if (strcmp(want, "saver") == 0) power_choice = PowerChoice::Saver;
                else if (strcmp(want, "deep") == 0) power_choice = PowerChoice::Deep;
                if (power_choice != before) {
                    save_power_choice();
                    apply_power_policy();
                }
                ESP_LOGW(kTag, "Power mode asked for by the phone: %s (now %s)", want, power_mode_name(effective_power_mode()));
                send_sync_status();
            } else if (strcmp(message.value, "@speak-prepare") == 0) {
                offer_speak();
            } else if (strcmp(message.value, "@firmware-prepare") == 0) {
                offer_upload(true);
            } else if (strcmp(message.value, "@firmware-revert") == 0) {
                if (xTaskCreate(revert_firmware_task, "fw_revert", 4096, nullptr, 4, nullptr) != pdPASS) {
                    report_audio_status("Update failed: could not start");
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

// What the board holds for paired phones, so a pairing that goes wrong can be explained: every
// bond's address and type, which keys it has (encryption key, identity key) and the identity
// address if the phone gave one.
void log_bonds(const char *when) {
    int count = esp_ble_get_bond_device_num();
    ESP_LOGW(kTag, "BONDS (%s): %d stored", when, count);
    if (count <= 0 || count > 8) return;
    // On the heap: this runs on the Bluetooth task, whose stack is small, and eight of these records
    // on it overflowed it and restarted the board on every connection.
    auto *list = static_cast<esp_ble_bond_dev_t *>(heap_caps_malloc(8 * sizeof(esp_ble_bond_dev_t), MALLOC_CAP_SPIRAM));
    if (list == nullptr) return;
    int n = 8;
    if (esp_ble_get_bond_device_list(&n, list) != ESP_OK) {
        heap_caps_free(list);
        return;
    }
    for (int i = 0; i < n; i++) {
        const uint8_t *a = list[i].bd_addr;
        const uint8_t *id = list[i].bond_key.pid_key.static_addr;
        ESP_LOGW(kTag, "BONDS (%s): #%d %02x:%02x:%02x:%02x:%02x:%02x type %d, keys 0x%02x (enc %s, id %s), identity %02x:%02x:%02x:%02x:%02x:%02x",
            when, i, a[0], a[1], a[2], a[3], a[4], a[5], static_cast<int>(list[i].bd_addr_type),
            static_cast<unsigned>(list[i].bond_key.key_mask),
            (list[i].bond_key.key_mask & ESP_BLE_ENC_KEY_MASK) ? "yes" : "NO",
            (list[i].bond_key.key_mask & ESP_BLE_ID_KEY_MASK) ? "yes" : "NO",
            id[0], id[1], id[2], id[3], id[4], id[5]);
    }
    heap_caps_free(list);
}

// A pairing that disappears while nothing is connected has happened (11 Oct 2026, between 17:32 and
// 19:10, with no restart). This notes the minute the count changes, so the lines logged around it
// say why. It runs from PSRAM and wakes twice a minute.
void bond_watch_task(void *) {
    int last = esp_ble_get_bond_device_num();
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(30000));
        const int now = esp_ble_get_bond_device_num();
        if (now != last) {
            ESP_LOGW(kTag, "BOND COUNT CHANGED: %d -> %d (up %lu s, connected %d)", last, now,
                static_cast<unsigned long>(esp_timer_get_time() / 1000000), connection_id != UINT16_MAX ? 1 : 0);
            log_bonds("after the count changed");
            last = now;
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
    case ESP_GAP_BLE_ADV_STOP_COMPLETE_EVT:
        if (adv_restart_pending && connection_id == UINT16_MAX) {
            adv_restart_pending = false;
            esp_ble_gap_start_advertising(&adv_params);
        }
        adv_restart_pending = false;
        break;
    case ESP_GAP_BLE_READ_RSSI_COMPLETE_EVT:
        if (param->read_rssi_cmpl.status == ESP_BT_STATUS_SUCCESS) {
            const int rssi = param->read_rssi_cmpl.rssi;
            const bool weak = rssi < -80;
            const bool moved = last_rssi_at_us == 0 || rssi - last_rssi_dbm >= 10 || last_rssi_dbm - rssi >= 10;
            last_rssi_dbm = rssi;
            last_rssi_at_us = esp_timer_get_time();
            if (weak || moved) ESP_LOGI(kTag, "Signal from the phone: %d dBm%s", rssi, weak ? " (weak)" : "");
        }
        break;
    case ESP_GAP_BLE_REMOVE_BOND_DEV_COMPLETE_EVT:
        ESP_LOGW(kTag, "BOND REMOVED (status %d)", static_cast<int>(param->remove_bond_dev_cmpl.status));
        log_bonds("after a bond was removed");
        break;
    case ESP_GAP_BLE_SEC_REQ_EVT:
        ESP_LOGW(kTag, "BLE security request event from the phone");
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
            ble_seen_since_boot = true;
            ensure_note_key();
            if (active_screen == DeviceScreen::Pairing) show_device_screen(DeviceScreen::Idle);
        } else {
            ESP_LOGW(kTag, "BLE security failed with %02x:%02x:%02x:%02x:%02x:%02x (address type %d): reason 0x%x, %d bonded phone(s) stored",
                a[0], a[1], a[2], a[3], a[4], a[5], auth.addr_type, auth.fail_reason, esp_ble_get_bond_device_num());
            log_bonds("after failed security");
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
    // A status message is best effort: if the Bluetooth stack refuses it, that must never take the board down.
    const esp_err_t status = esp_ble_gatts_send_indicate(
        server_if, connection_id, relay_handle, strlen(request),
        reinterpret_cast<uint8_t *>(const_cast<char *>(request)), false);
    if (status != ESP_OK) ESP_LOGW(kTag, "Status message not sent: %s", esp_err_to_name(status));
}

#ifdef CIRCUIT_DEV_CONSOLE
// "drop-next-link [ms]": cut the next Bluetooth link this many ms after the phone connects, in the middle of
// its security handshake, to test that a link failure no longer deletes the stored pairing.
void dev_drop_link_task(void *arg) {
    auto *bda = static_cast<uint8_t *>(arg);
    const int wait_ms = dev_drop_link_ms.exchange(-1);
    vTaskDelay(pdMS_TO_TICKS(wait_ms > 0 ? wait_ms : 1));
    ESP_LOGW(kTag, "DEV drop-next-link: cutting the link now");
    esp_ble_gap_disconnect(bda);
    heap_caps_free(bda);
    vTaskDelete(nullptr);
}
#endif

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
        // Ask the phone to keep the link relaxed: an event every 100 to 200 ms, and up to two skipped when there
        // is nothing to say. A message from the phone still arrives within about half a second.
        memcpy(connected_bda, param->connect.remote_bda, sizeof(connected_bda));
        apply_ble_rhythm();  // relaxed in Saver, slow below
    }
    {
        const uint8_t *a = param->connect.remote_bda;
        int bonded_count = esp_ble_get_bond_device_num();
        bool known = false;
        if (bonded_count > 0 && bonded_count <= 8) {
            auto *list = static_cast<esp_ble_bond_dev_t *>(heap_caps_malloc(8 * sizeof(esp_ble_bond_dev_t), MALLOC_CAP_SPIRAM));
            int n = 8;
            if (list != nullptr && esp_ble_get_bond_device_list(&n, list) == ESP_OK) {
                for (int i = 0; i < n; i++) {
                    if (memcmp(list[i].bd_addr, a, ESP_BD_ADDR_LEN) == 0) known = true;
                }
            }
            if (list != nullptr) heap_caps_free(list);
        }
        ESP_LOGI(kTag, "Short-Circuit connected: %02x:%02x:%02x:%02x:%02x:%02x (address type %d), %d bonded phone(s) stored, this address %s",
            a[0], a[1], a[2], a[3], a[4], a[5], param->connect.ble_addr_type, bonded_count, known ? "is one of them" : "is not listed");
        log_bonds("on connect");
        memcpy(peer_bda, param->connect.remote_bda, ESP_BD_ADDR_LEN);
        last_rssi_dbm = 0;
        last_rssi_at_us = 0;
        esp_err_t enc = esp_ble_set_encryption(param->connect.remote_bda, ESP_BLE_SEC_ENCRYPT_MITM);
        if (enc != ESP_OK) ESP_LOGW(kTag, "Could not ask for an encrypted link: %s", esp_err_to_name(enc));
#ifdef CIRCUIT_DEV_CONSOLE
        if (dev_drop_link_ms.load() >= 0) {
            auto *copy = static_cast<uint8_t *>(heap_caps_malloc(ESP_BD_ADDR_LEN, MALLOC_CAP_INTERNAL));
            if (copy != nullptr) {
                memcpy(copy, param->connect.remote_bda, ESP_BD_ADDR_LEN);
                xTaskCreate(dev_drop_link_task, "dev_drop", 3072, copy, 5, nullptr);
            }
        }
#endif
        break;
    }
    case ESP_GATTS_DISCONNECT_EVT:
        connection_id = UINT16_MAX;
        ble_encrypted = false;
        show_relay_disconnected();
        if (last_rssi_at_us != 0) {
            ESP_LOGI(kTag, "Client disconnected (reason 0x%x); last signal %d dBm, %d s before; advertising again",
                param->disconnect.reason, last_rssi_dbm, static_cast<int>((esp_timer_get_time() - last_rssi_at_us) / 1000000));
        } else {
            ESP_LOGI(kTag, "Client disconnected (reason 0x%x); no signal reading yet; advertising again", param->disconnect.reason);
        }
        ESP_ERROR_CHECK(esp_ble_gap_start_advertising(&adv_params));
        break;
    default:
        break;
    }
}

// Asks the stack for the link's signal strength every 20 s while a phone is connected.
void rssi_task(void *) {
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(20000));
        if (connection_id != UINT16_MAX) esp_ble_gap_read_rssi(peer_bda);
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
    log_bonds("at start-up");
    xTaskCreatePinnedToCoreWithCaps(bond_watch_task, "bond_watch", 3072, nullptr, 1, nullptr, tskNO_AFFINITY,
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
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

void wifi_rest() {
    if (wifi_resting || wifi_ssid[0] == '\0') return;  // already resting, or no network to rest
    if (circuit_sync::is_open() || update_busy() || after_wifi != AfterWifi::Nothing) return;
    wifi_resting = true;
    wifi_manual_disconnect = wifi_connected;  // the disconnect that follows is ours
    esp_wifi_disconnect();
    esp_wifi_stop();
    wifi_connected = false;
    wifi_internet_online = false;
    set_wifi_ui(WifiUi::Resting, "off to save power; on when needed");
    ESP_LOGW(kTag, "Wi-Fi resting (power mode %s)", power_mode_name(effective_power_mode()));
}

void wifi_wake() {
    if (!wifi_resting) return;
    wifi_resting = false;
    wifi_retries = 0;
    wifi_last_needed_ms = circuit_sync::now_ms();
    ESP_LOGW(kTag, "Wi-Fi waking");
    esp_wifi_start();  // the network is saved in flash
    set_wifi_ui(WifiUi::Connecting);
    esp_wifi_connect();
}

void wifi_wait_task(void *) {
    // Wi-Fi was off; wait for it (a few seconds) and do what was asked.
    char ip[16];
    int waited_ms = 0;
    while (waited_ms < 25000 && !(wifi_connected && circuit_sync::wifi_ip(ip, sizeof(ip)))) {
        vTaskDelay(pdMS_TO_TICKS(250));
        waited_ms += 250;
    }
    const AfterWifi action = after_wifi;
    const bool forced = after_wifi_forced;
    after_wifi = AfterWifi::Nothing;
    wifi_last_needed_ms = circuit_sync::now_ms();
    if (!(wifi_connected && circuit_sync::wifi_ip(ip, sizeof(ip)))) {
        report_audio_status("Wi-Fi did not connect: try again, or check the network");
        if (forced) flash_sync_result("ERR");
    } else if (action == AfterWifi::Sync) {
        start_audio_sync(forced);
    } else if (action == AfterWifi::Broadcast) {
        offer_upload(false);
    } else if (action == AfterWifi::Update) {
        offer_upload(true);
    }
    vTaskDelete(nullptr);
}

void request_after_wifi(AfterWifi action, bool forced) {
    if (after_wifi != AfterWifi::Nothing) return;  // already waiting for it
    after_wifi = action;
    after_wifi_forced = forced;
    wifi_wake();
    if (xTaskCreate(wifi_wait_task, "wifi_wait", 4096, nullptr, 4, nullptr) != pdPASS) {
        after_wifi = AfterWifi::Nothing;
        report_audio_status("Could not wake Wi-Fi");
    }
}

// The Bluetooth rhythm follows the power mode: relaxed (100 to 200 ms) in Saver, slow (about a second) below. The
// phone is asked to change an open link; advertising for a phone that is away changes as well.
void apply_ble_rhythm() {
    if (connection_id == UINT16_MAX) return;
    const bool slow = effective_power_mode() != PowerMode::Saver;
    esp_ble_conn_update_params_t params = {};
    memcpy(params.bda, connected_bda, sizeof(params.bda));
    params.min_int = slow ? 0x280 : 0x50;  // 800 ms : 100 ms
    params.max_int = slow ? 0x320 : 0xA0;  // 1000 ms : 200 ms
    params.latency = slow ? 3 : 2;
    params.timeout = slow ? 1000 : 400;    // 10 s : 4 s, above (1 + latency) x interval x 2 either way
    esp_ble_gap_update_conn_params(&params);
}

void apply_adv_rhythm() {
    const bool slow = effective_power_mode() != PowerMode::Saver;
    adv_params.adv_int_min = slow ? 0x640 : 0xA0;  // 1 s : 100 ms (units of 0.625 ms)
    adv_params.adv_int_max = slow ? 0x7D0 : 0x140;  // 1.25 s : 200 ms
    if (connection_id == UINT16_MAX) {  // advertising for a phone that is away: restart it with the new rhythm
        adv_restart_pending = true;
        esp_ble_gap_stop_advertising();
    }
}

void apply_power_policy() {
    ESP_LOGW(kTag, "Power policy: %s", power_mode_name(effective_power_mode()));
    apply_ble_rhythm();
    apply_adv_rhythm();
    if (effective_power_mode() == PowerMode::Saver) wifi_wake();  // resting ends at once; resting starts after a minute idle
}

void init_display() {
    BoardPower_Init();
    BoardPower_VBAT_ON();  // BoardPower_Init sets the pins up again; keep the battery latched
    // Input and output, so the real level of the latch pin can be read back and logged.
    gpio_set_direction(kBatteryLatchPin, GPIO_MODE_INPUT_OUTPUT);
    gpio_set_level(kBatteryLatchPin, 1);
    ESP_LOGI(kTag, "Battery latch (GPIO17) reads %d, key (GPIO18) reads %d", gpio_get_level(kBatteryLatchPin),
        gpio_get_level(GPIO_NUM_18));
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
        update_cog_obj = lv_img_create(lv_screen_active());
        lv_img_set_src(update_cog_obj, circuit_update_frames[0]);
        lv_obj_align(update_cog_obj, LV_ALIGN_TOP_MID, 0, 38);
        lv_obj_add_flag(update_cog_obj, LV_OBJ_FLAG_HIDDEN);

        // Header icons: positioned and shown by refresh_status_icons().
        icon_wifi_obj = lv_img_create(lv_screen_active());
        icon_phone_obj = lv_img_create(lv_screen_active());
        icon_storage_obj = lv_img_create(lv_screen_active());
        for (lv_obj_t *icon : {icon_wifi_obj, icon_phone_obj, icon_storage_obj}) lv_obj_add_flag(icon, LV_OBJ_FLAG_HIDDEN);

        // Battery: drawn with plain shapes (no artwork needed), placed by refresh_status_icons().
        battery_body = lv_obj_create(lv_screen_active());
        lv_obj_remove_style_all(battery_body);
        lv_obj_set_size(battery_body, 16, 10);
        lv_obj_set_style_border_width(battery_body, 1, 0);
        lv_obj_set_style_border_color(battery_body, lv_color_black(), 0);
        lv_obj_set_style_radius(battery_body, 2, 0);
        lv_obj_set_style_bg_color(battery_body, lv_color_white(), 0);
        lv_obj_set_style_bg_opa(battery_body, LV_OPA_COVER, 0);
        lv_obj_clear_flag(battery_body, LV_OBJ_FLAG_SCROLLABLE);
        battery_fill = lv_obj_create(battery_body);
        lv_obj_remove_style_all(battery_fill);
        lv_obj_set_pos(battery_fill, 1, 1);
        lv_obj_set_size(battery_fill, 12, 6);
        lv_obj_set_style_bg_color(battery_fill, lv_color_black(), 0);
        lv_obj_set_style_bg_opa(battery_fill, LV_OPA_COVER, 0);
        battery_bolt = lv_label_create(battery_body);
        lv_obj_set_style_text_font(battery_bolt, &lv_font_montserrat_12, 0);
        lv_label_set_text(battery_bolt, LV_SYMBOL_CHARGE);
        lv_obj_set_style_text_color(battery_bolt, lv_color_black(), 0);
        lv_obj_set_style_bg_color(battery_bolt, lv_color_white(), 0);
        lv_obj_set_style_bg_opa(battery_bolt, LV_OPA_COVER, 0);
        lv_obj_align(battery_bolt, LV_ALIGN_CENTER, 0, 0);
        lv_obj_add_flag(battery_bolt, LV_OBJ_FLAG_HIDDEN);
        battery_nub = lv_obj_create(lv_screen_active());
        lv_obj_remove_style_all(battery_nub);
        lv_obj_set_size(battery_nub, 2, 4);
        lv_obj_set_style_bg_color(battery_nub, lv_color_black(), 0);
        lv_obj_set_style_bg_opa(battery_nub, LV_OPA_COVER, 0);
        sleep_zzz_label = lv_label_create(lv_screen_active());
        lv_label_set_text(sleep_zzz_label, "zzz");
        lv_obj_set_style_text_font(sleep_zzz_label, &lv_font_montserrat_12, 0);
        lv_obj_set_style_text_letter_space(sleep_zzz_label, 1, 0);
        lv_obj_set_style_text_color(sleep_zzz_label, lv_color_black(), 0);
        lv_obj_set_style_bg_color(sleep_zzz_label, lv_color_white(), 0);
        lv_obj_set_style_bg_opa(sleep_zzz_label, LV_OPA_COVER, 0);
        lv_obj_align(sleep_zzz_label, LV_ALIGN_TOP_LEFT, 143, 165);  // under the end of the wordmark's underline
        lv_obj_add_flag(sleep_zzz_label, LV_OBJ_FLAG_HIDDEN);
        battery_label = lv_label_create(lv_screen_active());
        lv_obj_set_style_text_font(battery_label, &lv_font_montserrat_12, 0);
        lv_obj_set_style_text_color(battery_label, lv_color_black(), 0);
        lv_obj_set_style_bg_color(battery_label, lv_color_white(), 0);
        lv_obj_set_style_bg_opa(battery_label, LV_OPA_COVER, 0);
        for (lv_obj_t *part : {battery_body, battery_nub, battery_label}) lv_obj_add_flag(part, LV_OBJ_FLAG_HIDDEN);

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

        recording_moment_icon = lv_img_create(lv_screen_active());
        lv_img_set_src(recording_moment_icon, &circuit_moment_filled);
        lv_obj_align(recording_moment_icon, LV_ALIGN_TOP_LEFT, 116, 156);
        lv_obj_add_flag(recording_moment_icon, LV_OBJ_FLAG_HIDDEN);

        recording_moment_count = make_label(&lv_font_montserrat_14, 40, LV_TEXT_ALIGN_LEFT);
        lv_obj_align(recording_moment_count, LV_ALIGN_TOP_LEFT, 142, 159);
        lv_obj_add_flag(recording_moment_count, LV_OBJ_FLAG_HIDDEN);

        sync_progress_label = make_label(&lv_font_montserrat_24, 84, LV_TEXT_ALIGN_LEFT);
        lv_obj_set_style_text_letter_space(sync_progress_label, 1, 0);
        lv_obj_align(sync_progress_label, LV_ALIGN_TOP_LEFT, 116, 129);

        idle_date_label = make_label(&lv_font_montserrat_12, 100, LV_TEXT_ALIGN_LEFT);
        lv_obj_set_style_text_letter_space(idle_date_label, 1, 0);
        // Only as wide as the date: a wider box has a white background that would hide the battery number.
        lv_obj_set_width(idle_date_label, LV_SIZE_CONTENT);
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
    // First of all: keep the battery connected (see kBatteryLatchPin).
    {
        gpio_config_t latch = {};
        latch.pin_bit_mask = 1ULL << kBatteryLatchPin;
        latch.mode = GPIO_MODE_OUTPUT;
        gpio_config(&latch);
        gpio_set_level(kBatteryLatchPin, 1);
    }
    circuit_sdlog::install();  // lines are kept in memory until the card is up, then written to it
    boot_reset_reason = static_cast<int>(esp_reset_reason());
    ESP_LOGW(kTag, "Circuit firmware %s", esp_app_get_description()->version);
    ESP_LOGW(kTag, "Reset reason: %d (1=power-on 3=software 4=panic 5=int-wdt 6=task-wdt 7=wdt 9=brownout 15=brownout)",
        static_cast<int>(esp_reset_reason()));
    esp_err_t nvs_status = nvs_flash_init();
    if (nvs_status == ESP_ERR_NVS_NO_FREE_PAGES || nvs_status == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        // This wipes everything saved (pairings, keys, Wi-Fi). It must never go unrecorded.
        ESP_LOGE(kTag, "NVS ERASED at start-up (%s): all saved settings and pairings are gone",
            esp_err_to_name(nvs_status));
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    } else {
        ESP_ERROR_CHECK(nvs_status);
    }

    load_power_choice();
    crypto_self_test_ok = run_crypto_self_test();
    note_key_ready = circuit_secure::load_key(&note_key);
    ESP_LOGI(kTag, "Notes crypto self-test: %s; notes key: %s", crypto_self_test_ok ? "PASS" : "FAIL",
        note_key_ready ? "present" : "none yet");
    ESP_LOGI(kTag, "Moments self-test: %s", circuit_moments::selftest() ? "PASS" : "FAIL");
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
    // A broadcast message or firmware image left on the card by a restart or a cut session is never wanted again.
    remove(circuit_sync::kSpeakPath);
    remove(circuit_sync::kFirmwarePath);
    show_pending_from_card();
    Codec_StartInit();
    audio_devices_opened = true;  // Codec_StartInit() opened both directions
    audio_devices_close();        // they are opened for use only (see audio_devices_open)
    restore_clock_from_rtc();
    audio_ready = true;
    init_record_button();
    init_light_sleep();
    xTaskCreate(demo_animation_task, "demo_animation", 3072, nullptr, 2, &animation_task_handle);
    // 5 KB: the command handler runs deep, through file listing and the Wi-Fi sync start, and
    // 4 KB overflowed once note listing grew by one nested call. Its real use is logged below.
    xTaskCreate(text_display_task, "text_display", 5120, nullptr, 4, nullptr);
    xTaskCreate(status_icon_task, "status_icons", 4096, nullptr, 2, nullptr);
    xTaskCreate(sync_supervisor_task, "sync_supervisor", 10240, nullptr, 3, &sync_supervisor_handle);
    xTaskCreate(local_clock_task, "local_clock", 3072, nullptr, 2, nullptr);
    start_wifi();
    start_ble();
    xTaskCreate(rssi_task, "ble_rssi", 2560, nullptr, 2, nullptr);
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
    circuit_sync::log_heap("start-up done");
    {
        int battery_raw = 0;
        const int battery_mv = circuit_battery::read_mv(&battery_raw);
        if (battery_mv > 0) {
            ESP_LOGI(kTag, "Battery: %d mV, about %d%% (raw %d)", battery_mv,
                circuit_battery::percent_from_mv(battery_mv), battery_raw);
            if (battery_percent < 0) {
                const int first = ((circuit_battery::percent_from_mv(battery_mv) + 2) / 5) * 5;
                battery_percent = first > 100 ? 100 : first;
                update_power_mode(battery_percent);  // the policy is applied once the radios are up (start-up)
            }
        } else {
            ESP_LOGI(kTag, "Battery: not readable");
        }
    }
#ifdef CIRCUIT_DEV_CONSOLE
    xTaskCreate(dev_console_task, "dev_console", 6144, nullptr, 3, nullptr);
#endif
    if (esp_ble_get_bond_device_num() == 0) {
        if (boot_splash) show_pairing_code();
    } else {
        // Paired before this firmware had notes encryption: make the key now. Older
        // notes stay exactly as they are; only new recordings are encrypted.
        ensure_note_key();
        if (boot_splash) show_device_screen(DeviceScreen::Idle);
    }
}
