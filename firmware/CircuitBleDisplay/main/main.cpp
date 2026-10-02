#include <cstring>

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"
#include "esp_log.h"
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
constexpr size_t kMaxTextBytes = 160;
constexpr uint16_t kServiceHandles = 4;

const char *kTag = "Circuit";
QueueHandle_t text_queue;
lv_obj_t *message_label;
esp_gatt_if_t server_if = ESP_GATT_IF_NONE;
uint16_t service_handle;
uint16_t text_handle;

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

void text_display_task(void *) {
    TextMessage message{};
    while (true) {
        if (xQueueReceive(text_queue, &message, portMAX_DELAY) == pdTRUE) {
            ESP_LOGI(kTag, "Displaying BLE text: %s", message.value);
            update_message(message.value);
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
        text_handle = param->add_char.attr_handle;
        ESP_LOGI(kTag, "Text characteristic ready (handle %u)", text_handle);
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
        ESP_LOGI(kTag, "Short-Circuit connected");
        break;
    case ESP_GATTS_DISCONNECT_EVT:
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

void init_display() {
    BoardPower_Init();
    BoardPower_EPD_ON();
    PortLvgl_Start_Init();
    Lvgl_PortInit(flush_display);

    if (Lvgl_lock(-1)) {
        message_label = lv_label_create(lv_screen_active());
        lv_obj_set_width(message_label, 176);
        lv_obj_set_style_text_align(message_label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_set_style_text_font(message_label, &lv_font_montserrat_14, 0);
        lv_label_set_long_mode(message_label, LV_LABEL_LONG_WRAP);
        lv_label_set_text(message_label, "Circuit\nReady for\nShort-Circuit");
        lv_obj_center(message_label);
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
    start_ble();
}
