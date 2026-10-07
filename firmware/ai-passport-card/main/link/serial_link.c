// main/link/serial_link.c — see serial_link.h.
#include "link/serial_link.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "app_events.h"
#include "link/line_buf.h"
#include "link/proto.h"

static const char *TAG = "serial";

#define SERIAL_TX_BUF     1024
#define SERIAL_RX_BUF     2048
#define SERIAL_CHUNK      512                 // max bytes per driver write
#define SERIAL_WRITE_MS   50                  // per-chunk timeout when the host is slow/absent
#define SERIAL_LOCK_MS    200                 // wait for the port mutex before dropping a line
#define SERIAL_LOG_MAX    200                 // formatted log message bytes
#define SERIAL_LOG_RATE   20                  // JSON log lines per second

static SemaphoreHandle_t s_mutex;             // recursive: the log hook can run inside a write
static line_buf_t s_rx;
static volatile bool s_json_logs;
static vprintf_like_t s_prev_vprintf;
static uint32_t s_drops;
// Log hook scratch (protected by s_mutex; keeps the hook off small task stacks).
static char s_log_msg[SERIAL_LOG_MAX];
static char s_log_line[SERIAL_LOG_MAX + 48];
static int64_t s_log_window_us;
static int s_log_window_count;

static bool write_raw(const char *data, size_t len)
{
    while (len > 0) {
        size_t n = len > SERIAL_CHUNK ? SERIAL_CHUNK : len;
        int w = usb_serial_jtag_write_bytes(data, n, pdMS_TO_TICKS(SERIAL_WRITE_MS));
        if (w != (int)n) {
            s_drops++;
            return false;   // host not draining: drop the rest of this line
        }
        data += n;
        len -= n;
    }
    return true;
}

bool serial_link_write_line(const char *json, size_t len)
{
    if (!s_mutex || !json || len == 0 || len > PROTO_LINE_MAX) return false;
    if (xSemaphoreTakeRecursive(s_mutex, pdMS_TO_TICKS(SERIAL_LOCK_MS)) != pdTRUE) return false;
    bool ok = write_raw(json, len) && write_raw("\n", 1);
    xSemaphoreGiveRecursive(s_mutex);
    return ok;
}

// Replacement for the ESP_LOG vprintf, installed for good by serial_link_start().
// It is the *only* other writer on this port, so it takes the same mutex as
// serial_link_write_line() whether or not the logs are wrapped in JSON: that is what
// keeps the boot `hello` from being cut in half by "Returned from app_main()".
// Runs on the logging task's stack: keep it small, never log from here, never block
// for long. CONFIG_LOG_VERSION=1, so one call carries one complete log line.
// Plain (pre-muteLogs) lines go to the previous handler, unchanged and un-rate-limited.
static int log_vprintf(const char *fmt, va_list args)
{
    vprintf_like_t prev = s_prev_vprintf;
    if (!s_mutex) return prev ? prev(fmt, args) : 0;
    if (xSemaphoreTakeRecursive(s_mutex, pdMS_TO_TICKS(SERIAL_LOCK_MS)) != pdTRUE) return 0;
    if (!s_json_logs) {
        int written = prev ? prev(fmt, args) : 0;
        xSemaphoreGiveRecursive(s_mutex);
        return written;
    }

    int64_t now = esp_timer_get_time();
    if (now - s_log_window_us >= 1000000) {
        s_log_window_us = now;
        s_log_window_count = 0;
    }
    if (s_log_window_count >= SERIAL_LOG_RATE) {
        xSemaphoreGiveRecursive(s_mutex);
        return 0;
    }
    s_log_window_count++;

    int n = vsnprintf(s_log_msg, sizeof(s_log_msg), fmt, args);
    if (n < 0) n = 0;
    if ((size_t)n >= sizeof(s_log_msg)) n = sizeof(s_log_msg) - 1;
    while (n > 0 && (s_log_msg[n - 1] == '\n' || s_log_msg[n - 1] == '\r')) s_log_msg[--n] = '\0';
    // ESP_LOG lines start with the level letter: "I (1234) tag: message".
    char lvl = 'I';
    if (n > 1 && s_log_msg[1] == ' ' && strchr("EWIDV", s_log_msg[0])) lvl = s_log_msg[0];
    int len = proto_format_log(s_log_line, sizeof(s_log_line), lvl, s_log_msg);
    if (len > 0) (void)(write_raw(s_log_line, (size_t)len) && write_raw("\n", 1));
    xSemaphoreGiveRecursive(s_mutex);
    return n;
}

// Only flips the format; the hook itself stays installed so the mutex keeps both
// shapes of log line atomic against serial_link_write_line().
void serial_link_set_json_logs(bool on) { s_json_logs = on; }

bool serial_link_json_logs(void) { return s_json_logs; }

bool serial_link_usb_present(void) { return usb_serial_jtag_is_connected(); }

static void on_rx_line(const char *line, size_t len, void *ctx)
{
    (void)ctx;
    if (!app_events_post_line(EV_SRC_SERIAL, line, len)) s_drops++;
}

static void reader_task(void *arg)
{
    (void)arg;
    uint8_t buf[128];
    for (;;) {
        int n = usb_serial_jtag_read_bytes(buf, sizeof(buf), pdMS_TO_TICKS(250));
        if (n > 0) line_buf_push(&s_rx, buf, (size_t)n, on_rx_line, NULL);
    }
}

esp_err_t serial_link_start(void)
{
    if (s_mutex) return ESP_OK;
    s_mutex = xSemaphoreCreateRecursiveMutex();
    if (!s_mutex) return ESP_ERR_NO_MEM;
    line_buf_init(&s_rx);

    // Take over ESP_LOG before anything else on this port can log, and keep it for
    // the whole run: from here on every line leaving the device is written under
    // s_mutex, plain text and JSON alike.
    vprintf_like_t prev = esp_log_set_vprintf(log_vprintf);
    if (prev != log_vprintf) s_prev_vprintf = prev;

    usb_serial_jtag_driver_config_t cfg = {
        .tx_buffer_size = SERIAL_TX_BUF,
        .rx_buffer_size = SERIAL_RX_BUF,
    };
    esp_err_t e = usb_serial_jtag_driver_install(&cfg);
    if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "usb_serial_jtag_driver_install: %s", esp_err_to_name(e));
        return e;
    }
    // Route stdout/ESP_LOG through the driver (interrupt driven, bounded blocking).
    usb_serial_jtag_vfs_use_driver();

    if (xTaskCreate(reader_task, "serial_rx", 3072, NULL, 5, NULL) != pdPASS) {
        ESP_LOGE(TAG, "reader task create failed");
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "USB Serial/JTAG link ready (host %s)",
             usb_serial_jtag_is_connected() ? "present" : "absent");
    return ESP_OK;
}
