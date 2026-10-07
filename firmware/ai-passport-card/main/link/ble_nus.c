// main/link/ble_nus.c — see ble_nus.h. Pattern follows the upstream demo_ble.c
// lifecycle (nimble_port_init + host task) and the community NUS implementation
// (GATT table, MTU-3 fragmentation, advertise on sync/disconnect).
#include "link/ble_nus.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "sdkconfig.h"

static const char *TAG = "ble";
static char s_name[20] = "SpatialCard";

const char *ble_nus_device_name(void) { return s_name; }

#if CONFIG_CARD_ENABLE_BLE

#include "esp_mac.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "host/ble_att.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_hs_mbuf.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "os/os_mbuf.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "app_events.h"
#include "link/line_buf.h"
#include "link/proto.h"

#define NUS_MTU_PREFERRED   247
#define NUS_TX_CHUNK_MAX    (NUS_MTU_PREFERRED - 3)
#define NUS_TX_RETRY_MS     5
#define NUS_TX_RETRY_MAX    40     // 200 ms of back-pressure before giving up on a line

// 6e400001-b5a3-f393-e0a9-e50e24dcca9e and its RX/TX siblings, little-endian bytes.
static const ble_uuid128_t UUID_SVC = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0, 0x93, 0xf3, 0xa3, 0xb5, 0x01, 0x00, 0x40, 0x6e);
static const ble_uuid128_t UUID_RX = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0, 0x93, 0xf3, 0xa3, 0xb5, 0x02, 0x00, 0x40, 0x6e);
static const ble_uuid128_t UUID_TX = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0, 0x93, 0xf3, 0xa3, 0xb5, 0x03, 0x00, 0x40, 0x6e);

static volatile uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static volatile bool s_subscribed;
static volatile bool s_synced;
static bool s_started;
static uint8_t s_addr_type;
static uint16_t s_tx_handle;
static SemaphoreHandle_t s_tx_mutex;
static line_buf_t s_rx;   // only touched from the NimBLE host task

static int gap_event(struct ble_gap_event *event, void *arg);

static void post(app_ev_kind_t kind)
{
    const app_event_t ev = { .src = EV_SRC_BLE, .kind = kind };
    (void)app_events_post(&ev);
}

static void on_rx_line(const char *line, size_t len, void *ctx)
{
    (void)ctx;
    if (!app_events_post_line(EV_SRC_BLE, line, len)) ESP_LOGW(TAG, "rx line dropped");
}

static int gatt_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;
    if (conn_handle != s_conn) return BLE_ATT_ERR_UNLIKELY;
    for (struct os_mbuf *om = ctxt->om; om != NULL; om = SLIST_NEXT(om, om_next)) {
        line_buf_push(&s_rx, om->om_data, om->om_len, on_rx_line, NULL);
    }
    return 0;
}

static const struct ble_gatt_svc_def GATT_SERVICES[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &UUID_SVC.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &UUID_RX.u,
                .access_cb = gatt_access,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                .uuid = &UUID_TX.u,
                .access_cb = gatt_access,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_tx_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

static int advertise(void)
{
    if (s_conn != BLE_HS_CONN_HANDLE_NONE || !s_synced) return 0;
    if (ble_gap_adv_active()) return 0;

    struct ble_hs_adv_fields fields = { 0 };
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)&UUID_SVC;   // 3 + 18 bytes: fits the 31-byte ADV
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) { ESP_LOGE(TAG, "adv fields rc=%d", rc); return rc; }

    struct ble_hs_adv_fields rsp = { 0 };           // name goes in the scan response
    rsp.name = (const uint8_t *)s_name;
    rsp.name_len = strlen(s_name);
    rsp.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&rsp);
    if (rc != 0) { ESP_LOGE(TAG, "adv rsp rc=%d", rc); return rc; }

    struct ble_gap_adv_params params = { 0 };
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(s_addr_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) ESP_LOGE(TAG, "adv start rc=%d", rc);
    else ESP_LOGI(TAG, "advertising as %s", s_name);
    return rc;
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0) {
            ESP_LOGW(TAG, "connect failed status=%d", event->connect.status);
            advertise();
            return 0;
        }
        s_conn = event->connect.conn_handle;
        s_subscribed = false;
        line_buf_init(&s_rx);
        ESP_LOGI(TAG, "central connected handle=%u", s_conn);
        post(EV_BLE_CONNECTED);
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "central disconnected reason=%d", event->disconnect.reason);
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        s_subscribed = false;
        post(EV_BLE_DISCONNECTED);
        advertise();
        return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        return 0;

    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.conn_handle == s_conn && event->subscribe.attr_handle == s_tx_handle) {
            bool now = event->subscribe.cur_notify != 0;
            bool was = s_subscribed;
            s_subscribed = now;
            ESP_LOGI(TAG, "TX notify %s", now ? "on" : "off");
            if (now && !was) post(EV_BLE_SUBSCRIBED);
        }
        return 0;

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU %u", event->mtu.value);
        return 0;

    case BLE_GAP_EVENT_REPEAT_PAIRING:
        return BLE_GAP_REPEAT_PAIRING_IGNORE;

    default:
        return 0;
    }
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "host reset reason=%d", reason);
    s_synced = false;
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) {
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        s_subscribed = false;
        post(EV_BLE_DISCONNECTED);
    }
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc == 0) rc = ble_hs_id_infer_auto(0, &s_addr_type);
    if (rc != 0) { ESP_LOGE(TAG, "address rc=%d", rc); return; }
    s_synced = true;
    advertise();
}

static void host_task(void *arg)
{
    (void)arg;
    nimble_port_run();               // returns after nimble_port_stop()
    nimble_port_freertos_deinit();
}

esp_err_t ble_nus_start(void)
{
    if (s_started) return ESP_OK;
    s_tx_mutex = xSemaphoreCreateMutex();
    if (!s_tx_mutex) return ESP_ERR_NO_MEM;

    uint8_t mac[6] = { 0 };
    if (esp_read_mac(mac, ESP_MAC_BT) == ESP_OK) {
        snprintf(s_name, sizeof(s_name), "SpatialCard-%02X%02X", mac[4], mac[5]);
    }

    esp_err_t e = nimble_port_init();
    if (e != ESP_OK) { ESP_LOGE(TAG, "nimble_port_init: %s", esp_err_to_name(e)); return e; }

    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.gatts_register_cb = NULL;
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;   // Just-Works
    ble_hs_cfg.sm_bonding = 0;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = 0;
    ble_hs_cfg.sm_their_key_dist = 0;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    int rc = ble_gatts_count_cfg(GATT_SERVICES);
    if (rc == 0) rc = ble_gatts_add_svcs(GATT_SERVICES);
    if (rc == 0) rc = ble_svc_gap_device_name_set(s_name);
    if (rc == 0) rc = ble_att_set_preferred_mtu(NUS_MTU_PREFERRED);
    if (rc != 0) {
        ESP_LOGE(TAG, "GATT setup rc=%d", rc);
        nimble_port_deinit();
        return ESP_FAIL;
    }
    line_buf_init(&s_rx);
    nimble_port_freertos_init(host_task);
    s_started = true;
    ESP_LOGI(TAG, "NimBLE NUS started, name=%s", s_name);
    return ESP_OK;
}

bool ble_nus_is_connected(void) { return s_conn != BLE_HS_CONN_HANDLE_NONE; }
bool ble_nus_is_subscribed(void) { return ble_nus_is_connected() && s_subscribed; }

bool ble_nus_send_line(const char *json, size_t len)
{
    if (!json || len == 0 || len > PROTO_LINE_MAX || !s_started) return false;
    if (!ble_nus_is_subscribed() || !s_tx_mutex) return false;
    if (xSemaphoreTake(s_tx_mutex, pdMS_TO_TICKS(500)) != pdTRUE) return false;

    uint16_t conn = s_conn;
    uint16_t mtu = ble_att_mtu(conn);
    size_t frag = mtu > 3 ? (size_t)mtu - 3 : 20;
    if (frag > NUS_TX_CHUNK_MAX) frag = NUS_TX_CHUNK_MAX;

    bool ok = true;
    uint8_t chunk[NUS_TX_CHUNK_MAX];
    size_t total = len + 1;   // line + '\n'
    for (size_t off = 0; off < total && ok; ) {
        size_t n = total - off < frag ? total - off : frag;
        for (size_t i = 0; i < n; i++) chunk[i] = (off + i < len) ? (uint8_t)json[off + i] : '\n';
        int attempts = 0;
        for (;;) {
            if (!ble_nus_is_subscribed() || s_conn != conn) { ok = false; break; }
            struct os_mbuf *om = ble_hs_mbuf_from_flat(chunk, (uint16_t)n);
            int rc = om ? ble_gatts_notify_custom(conn, s_tx_handle, om) : BLE_HS_ENOMEM;
            if (rc == 0) break;
            if (rc != BLE_HS_ENOMEM || ++attempts > NUS_TX_RETRY_MAX) {
                ESP_LOGW(TAG, "notify rc=%d", rc);
                ok = false;
                break;
            }
            vTaskDelay(pdMS_TO_TICKS(NUS_TX_RETRY_MS));   // controller/msys back-pressure
        }
        off += n;
    }
    xSemaphoreGive(s_tx_mutex);
    return ok;
}

void ble_nus_readvertise(void)
{
    if (!s_started || s_conn != BLE_HS_CONN_HANDLE_NONE) return;
    (void)ble_gap_adv_stop();
    advertise();
}

void ble_nus_stop(void)
{
    if (!s_started) return;
    (void)ble_gap_adv_stop();
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) {
        (void)ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM);
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    int rc = nimble_port_stop();
    if (rc == 0) nimble_port_deinit();
    else ESP_LOGW(TAG, "nimble_port_stop rc=%d", rc);
    s_started = false;
}

#else  // CONFIG_CARD_ENABLE_BLE off: browser simulator / BLE-less builds

esp_err_t ble_nus_start(void)
{
    ESP_LOGW(TAG, "BLE disabled by CONFIG_CARD_ENABLE_BLE");
    return ESP_ERR_NOT_SUPPORTED;
}
bool ble_nus_is_connected(void) { return false; }
bool ble_nus_is_subscribed(void) { return false; }
bool ble_nus_send_line(const char *json, size_t len) { (void)json; (void)len; return false; }
void ble_nus_readvertise(void) {}
void ble_nus_stop(void) {}

#endif
