#include <cstdio>
#include <cstring>

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_event.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"

#include "lwip/inet.h"
#include "ping/ping_sock.h"
#include "nvs_flash.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "lvgl.h"
#include "port_display.h"
#include "port_lvgl.h"
#include "port_power.h"

namespace {

constexpr char kDeviceName[] = "Circuit";
constexpr uint16_t kServiceUuid = 0xFFF0;
constexpr uint16_t kTextUuid = 0xFFF1;
constexpr uint16_t kRelayUuid = 0xFFF2;
constexpr size_t kMaxTextBytes = 160;
constexpr char kWifiCommandPrefix[] = "@wifi\n";
constexpr char kWifiScanCommand[] = "@wifi-scan";
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

void send_relay_request(const char *request);

struct TextMessage {
    char value[kMaxTextBytes + 1];
};

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
    xTaskCreate(text_display_task, "text_display", 4096, nullptr, 4, nullptr);
    start_wifi();
    start_ble();
}
