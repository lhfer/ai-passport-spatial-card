// main/main.c — Spatial Card firmware entry: boot order and nothing else.
//   nvs_flash_init -> app_state_init (queue + NVS state) -> bsp_i2c -> bsp_display
//   -> bsp_lvgl -> screen -> bsp_button_init(on_key: enqueue only) -> bsp_audio + cues
//   -> bsp_battery -> serial_link -> ble_nus (CONFIG_CARD_ENABLE_BLE) -> app task
// Everything after this file runs in worker tasks; the button callback only enqueues.
#include "bsp_audio.h"
#include "bsp_battery.h"
#include "bsp_button.h"
#include "bsp_display.h"
#include "bsp_i2c.h"
#include "bsp_pins.h"
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "app_events.h"
#include "app_state.h"
#include "audio/cues.h"
#include "card_types.h"
#include "link/ble_nus.h"
#include "link/serial_link.h"

static const char *TAG = "main";

#if CONFIG_CARD_ENABLE_BLE
#define BLE_BUILD "on"
#else
#define BLE_BUILD "off"
#endif

// Runs on the shared esp_timer task (iot_button): enqueue and return.
static void on_key(bsp_btn_t btn, bsp_btn_ev_t ev, void *user)
{
    (void)user;
    app_event_t e = { .src = EV_SRC_BTN, .kind = EV_BTN };
    e.u.btn.btn = (uint8_t)btn;
    e.u.btn.ev = (uint8_t)ev;
    (void)app_events_post(&e);
}

static void nvs_init(void)
{
    esp_err_t e = nvs_flash_init();
    if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        // Our own namespace only holds the cached follower count: recreate it.
        ESP_LOGW(TAG, "NVS needs erase (%s)", esp_err_to_name(e));
        if (nvs_flash_erase() == ESP_OK) e = nvs_flash_init();
    }
    if (e != ESP_OK) ESP_LOGE(TAG, "nvs_flash_init: %s", esp_err_to_name(e));
}

void app_main(void)
{
    ESP_LOGI(TAG, "Spatial Card fw %s (screen %s mm wide, BLE %s)", CARD_FW_VERSION,
             CONFIG_CARD_SCREEN_WIDTH_MM, BLE_BUILD);
    nvs_init();
    ESP_ERROR_CHECK(app_state_init());

    bsp_i2c_init();
    if (bsp_display_init() != ESP_OK || !bsp_lvgl_init()) {
        ESP_LOGE(TAG, "display/LVGL init failed (MOSI=%d SCLK=%d CS=%d DC=%d BL=%d)",
                 BSP_LCD_MOSI, BSP_LCD_SCLK, BSP_LCD_CS, BSP_LCD_DC, BSP_LCD_BL);
        return;
    }
    ESP_ERROR_CHECK(app_state_ui_init());
    bsp_display_backlight(100);   // power_policy takes over once the app task runs

    esp_err_t e = bsp_button_init(on_key, NULL);
    if (e != ESP_OK) ESP_LOGE(TAG, "buttons unavailable: %s", esp_err_to_name(e));

    e = bsp_audio_init();
    if (e == ESP_OK) e = cues_start();
    if (e != ESP_OK) ESP_LOGE(TAG, "audio cues unavailable: %s", esp_err_to_name(e));

    e = bsp_battery_init();
    if (e != ESP_OK) ESP_LOGW(TAG, "battery gauge unavailable: %s (soc/mv report -1)", esp_err_to_name(e));

    e = serial_link_start();
    if (e != ESP_OK) ESP_LOGE(TAG, "serial link failed: %s", esp_err_to_name(e));

    e = ble_nus_start();
    if (e != ESP_OK && e != ESP_ERR_NOT_SUPPORTED) ESP_LOGE(TAG, "BLE failed: %s", esp_err_to_name(e));

    ESP_ERROR_CHECK(app_state_start());
    ESP_LOGI(TAG, "boot complete, free heap %lu", (unsigned long)esp_get_free_heap_size());
}
