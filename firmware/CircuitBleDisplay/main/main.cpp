#include <cstdio>
#include <cstring>

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_vfs_fat.h"
#include "esp_wifi.h"

#include "lwip/inet.h"
#include "ping/ping_sock.h"
#include "nvs_flash.h"
#include "sdmmc_cmd.h"
#include "driver/sdmmc_host.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "lvgl.h"
#include "port_display.h"
#include "port_lvgl.h"
#include "port_power.h"
#include "port_codec.h"

namespace {

constexpr char kDeviceName[] = "Circuit";
constexpr uint16_t kServiceUuid = 0xFFF0;
constexpr uint16_t kTextUuid = 0xFFF1;
constexpr uint16_t kRelayUuid = 0xFFF2;
constexpr size_t kMaxTextBytes = 160;
constexpr char kWifiCommandPrefix[] = "@wifi\n";
constexpr char kWifiScanCommand[] = "@wifi-scan";
constexpr char kSdMountPath[] = "/sdcard";
constexpr char kSdTestFile[] = "/sdcard/CIRCUIT.TXT";
constexpr char kAudioFile[] = "/sdcard/CIRCUIT.WAV";
constexpr uint32_t kAudioSampleRate = 16000;
constexpr uint16_t kAudioChannels = 2;
constexpr uint16_t kAudioBitsPerSample = 16;
constexpr size_t kAudioBufferBytes = 4096;
constexpr uint32_t kMaxRecordingSeconds = 30;
constexpr uint16_t kServiceHandles = 6;

const char *kTag = "Circuit";
QueueHandle_t text_queue;
lv_obj_t *message_label;
lv_obj_t *connection_label;
esp_gatt_if_t server_if = ESP_GATT_IF_NONE;
uint16_t service_handle;
uint16_t text_handle;
uint16_t relay_handle;
uint16_t connection_id = UINT16_MAX;
sdmmc_card_t *sd_card = nullptr;
bool audio_ready = false;
bool audio_busy = false;
volatile bool recording_active = false;
volatile bool recording_stop_requested = false;

void send_relay_request(const char *request);

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

void update_message(const char *message) {
    if (!Lvgl_lock(-1)) {
        return;
    }
    lv_label_set_text(message_label, message);
    Lvgl_unlock();
}

void update_connection_status(const char *status) {
    if (!Lvgl_lock(-1)) {
        return;
    }
    lv_label_set_text(connection_label, status);
    Lvgl_unlock();
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
        update_storage_status("MicroSD: ready\nStorage verified");
    } else {
        ESP_LOGW(kTag, "MicroSD readback test failed");
        update_storage_status("MicroSD: mounted\nRead test failed");
    }
}

void finish_audio_task() {
    audio_busy = false;
    recording_active = false;
    vTaskDelete(nullptr);
}

void report_audio_status(const char *status) {
    char message[kMaxTextBytes + 1] = "@audio-status\n";
    strncat(message, status, sizeof(message) - strlen(message) - 1);
    send_relay_request(message);
}

void record_audio_task(void *argument) {
    const uint32_t seconds = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(argument));
    if (!audio_ready || sd_card == nullptr) {
        update_storage_status("MicroSD required\nCannot record audio");
        report_audio_status("Recording failed: MicroSD unavailable");
        finish_audio_task();
        return;
    }

    FILE *file = fopen(kAudioFile, "wb");
    if (file == nullptr) {
        update_storage_status("Audio record failed\nCannot create WAV file");
        report_audio_status("Recording failed: cannot create file");
        finish_audio_task();
        return;
    }

    WavHeader header{};
    fwrite(&header, sizeof(header), 1, file);
    uint8_t *buffer = static_cast<uint8_t *>(heap_caps_malloc(kAudioBufferBytes, MALLOC_CAP_SPIRAM));
    if (buffer == nullptr) {
        fclose(file);
        update_storage_status("Audio record failed\nNot enough memory");
        report_audio_status("Recording failed: memory unavailable");
        finish_audio_task();
        return;
    }

    const uint32_t target_bytes = seconds * header.byte_rate;
    uint32_t recorded_bytes = 0;
    update_storage_status("Recording audio…\nPlease speak near Circuit");
    report_audio_status("Recording started: speak near Circuit");
    while (recorded_bytes < target_bytes && !recording_stop_requested) {
        const size_t bytes = (target_bytes - recorded_bytes) < kAudioBufferBytes
            ? target_bytes - recorded_bytes : kAudioBufferBytes;
        if (Codec_RecordData(buffer, bytes) != ESP_OK || fwrite(buffer, 1, bytes, file) != bytes) {
            break;
        }
        recorded_bytes += bytes;
    }
    heap_caps_free(buffer);

    header.data_size = recorded_bytes;
    header.file_size = recorded_bytes + sizeof(WavHeader) - 8;
    fseek(file, 0, SEEK_SET);
    fwrite(&header, sizeof(header), 1, file);
    fclose(file);

    const bool completed = recorded_bytes == target_bytes;
    update_storage_status(completed
        ? "Recording saved\nReady to play"
        : "Recording stopped\nReady to play");
    report_audio_status(completed
        ? "Recording saved: ready to play"
        : "Recording stopped: ready to play");
    finish_audio_task();
}

void play_audio_task(void *) {
    FILE *file = fopen(kAudioFile, "rb");
    WavHeader header{};
    if (!audio_ready || file == nullptr || fread(&header, sizeof(header), 1, file) != 1 ||
        memcmp(header.riff, "RIFF", 4) != 0 || memcmp(header.wave, "WAVE", 4) != 0) {
        if (file != nullptr) fclose(file);
        update_storage_status("No recording found\nRecord audio first");
        report_audio_status("Playback failed: no recording found");
        finish_audio_task();
        return;
    }

    uint8_t *buffer = static_cast<uint8_t *>(heap_caps_malloc(kAudioBufferBytes, MALLOC_CAP_SPIRAM));
    if (buffer == nullptr) {
        fclose(file);
        update_storage_status("Playback failed\nNot enough memory");
        report_audio_status("Playback failed: memory unavailable");
        finish_audio_task();
        return;
    }

    update_storage_status("Playing recording…\nSpeaker active");
    report_audio_status("Playing latest recording");
    size_t bytes = 0;
    while ((bytes = fread(buffer, 1, kAudioBufferBytes, file)) > 0) {
        if (Codec_PlaybackData(buffer, bytes) != ESP_OK) break;
    }
    heap_caps_free(buffer);
    fclose(file);
    update_storage_status("Playback complete\nReady to record");
    report_audio_status("Playback complete");
    finish_audio_task();
}

void start_recording(char *command) {
    uint32_t seconds = 5;
    char *duration = strchr(command, '\n');
    if (duration != nullptr) {
        seconds = strtoul(duration + 1, nullptr, 10);
    }
    if (seconds == 0 || seconds > kMaxRecordingSeconds) {
        update_storage_status("Recording length: 1–30 sec");
        report_audio_status("Recording failed: choose 1–30 seconds");
        return;
    }
    if (audio_busy) {
        update_storage_status("Audio is busy\nPlease wait");
        report_audio_status("Audio is busy");
        return;
    }
    audio_busy = true;
    recording_active = true;
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

void start_playback() {
    if (audio_busy) {
        update_storage_status("Audio is busy\nPlease wait");
        report_audio_status("Audio is busy");
        return;
    }
    audio_busy = true;
    xTaskCreate(play_audio_task, "audio_play", 6144, nullptr, 5, nullptr);
}

void on_ping_success(esp_ping_handle_t, void *) {
    update_connection_status("Wi-Fi: connected\nInternet: online\nPhone relay: unavailable");
}

void on_ping_end(esp_ping_handle_t handle, void *) {
    uint32_t replies = 0;
    uint32_t replies_size = sizeof(replies);
    esp_ping_get_profile(handle, ESP_PING_PROF_REPLY, &replies, replies_size);
    if (replies == 0) {
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

void wifi_event_handler(void *, esp_event_base_t event_base, int32_t event_id, void *) {
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_CONNECTED) {
        update_connection_status("Wi-Fi: connected\nInternet: checking…\nPhone relay: unavailable");
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        update_connection_status("Wi-Fi: offline\nInternet: offline\nPhone relay: unavailable");
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        check_wifi_internet();
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
        return;
    }

    ESP_ERROR_CHECK(esp_wifi_disconnect());
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &config));
    update_connection_status("Wi-Fi: connecting…\nInternet: checking…\nPhone relay: unavailable");
    ESP_ERROR_CHECK(esp_wifi_connect());
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
            } else if (strcmp(message.value, "@relay-test") == 0) {
                update_connection_status("Wi-Fi: offline\nInternet: checking phone relay…");
                send_relay_request("@relay\nCHECK");
            } else if (strncmp(message.value, "@relay-result\n", 14) == 0) {
                const bool online = strcmp(message.value + 14, "online") == 0;
                update_connection_status(online
                    ? "Wi-Fi: offline\nInternet: phone relay online"
                    : "Wi-Fi: offline\nInternet: phone relay offline");
            } else if (strncmp(message.value, kWifiCommandPrefix, strlen(kWifiCommandPrefix)) == 0) {
                ESP_LOGI(kTag, "Received Wi-Fi configuration");
                provision_wifi(message.value);
            } else {
                ESP_LOGI(kTag, "Displaying BLE text: %s", message.value);
                update_message(message.value);
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
            service_handle, &text_uuid, ESP_GATT_PERM_WRITE,
            ESP_GATT_CHAR_PROP_BIT_WRITE | ESP_GATT_CHAR_PROP_BIT_WRITE_NR, &text_value, nullptr));
        break;
    }
    case ESP_GATTS_ADD_CHAR_EVT:
        if (param->add_char.char_uuid.uuid.uuid16 == kTextUuid) {
            text_handle = param->add_char.attr_handle;
            esp_bt_uuid_t relay_uuid = {.len = ESP_UUID_LEN_16, .uuid = {.uuid16 = kRelayUuid}};
            esp_attr_value_t relay_value = {.attr_max_len = kMaxTextBytes, .attr_len = 0, .attr_value = nullptr};
            ESP_ERROR_CHECK(esp_ble_gatts_add_char(
                service_handle, &relay_uuid, ESP_GATT_PERM_READ,
                ESP_GATT_CHAR_PROP_BIT_READ | ESP_GATT_CHAR_PROP_BIT_NOTIFY, &relay_value, nullptr));
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
                service_handle, &descriptor_uuid, ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, &descriptor, nullptr));
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
        ESP_LOGI(kTag, "Short-Circuit connected");
        break;
    case ESP_GATTS_DISCONNECT_EVT:
        connection_id = UINT16_MAX;
        ESP_LOGI(kTag, "Client disconnected; advertising again");
        ESP_ERROR_CHECK(esp_ble_gap_start_advertising(&adv_params));
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
    ESP_ERROR_CHECK(esp_ble_gap_register_callback(gap_event_handler));
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
        update_connection_status("Wi-Fi: reconnecting…\nInternet: checking…\nPhone relay: unavailable");
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

        message_label = lv_label_create(lv_screen_active());
        lv_obj_set_width(message_label, 176);
        lv_obj_set_style_text_align(message_label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_set_style_text_font(message_label, &lv_font_montserrat_14, 0);
        lv_label_set_long_mode(message_label, LV_LABEL_LONG_WRAP);
        lv_label_set_text(message_label, "Circuit\nReady for\nShort-Circuit");
        lv_obj_align(message_label, LV_ALIGN_BOTTOM_MID, 0, -12);
        Lvgl_unlock();
    }
}

}  // namespace

extern "C" void app_main(void) {
    esp_err_t nvs_status = nvs_flash_init();
    if (nvs_status == ESP_ERR_NVS_NO_FREE_PAGES || nvs_status == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    } else {
        ESP_ERROR_CHECK(nvs_status);
    }

    text_queue = xQueueCreate(4, sizeof(TextMessage));
    configASSERT(text_queue);
    init_display();
    init_sd_card();
    Codec_StartInit();
    audio_ready = true;
    xTaskCreate(text_display_task, "text_display", 4096, nullptr, 4, nullptr);
    start_wifi();
    start_ble();
}
