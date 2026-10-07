// main/app_state.c — see app_state.h and docs/protocol.md.
//
// AR-mode repaint handshake (protocol section "切屏握手"):
//   will_change{id,kind,theme,region} -> wait VP ack <= 300 ms (proceed on timeout)
//   -> repaint under bsp_lvgl_lock (+ lv_refr_now) -> changed{id,theme}
// kind "theme" repaints synchronously; kind "stat" runs the flip animation and
// sends `changed` when the LVGL task reports EV_FLIP_DONE.
//
// The bottom strip normally shows the follower count. A `strip{text}` command
// (protocol section "底条覆盖") overrides it until `strip{}` (no text), the BLE
// central disconnecting, or the STRIP_WATCHDOG_S timer restores it. While an
// override is up, incoming `stats` only update the stored follower text silently
// and `celebrate` flips whatever the strip currently shows.
//
// CONFIG_CARD_SCREEN_LOCK (default y) pins the screen to CONFIG_CARD_DEFAULT_THEME
// because the ARKit reference object was trained with that screen: the boot theme
// ignores what NVS remembers, idle UP/DOWN stop cycling it (the `button` reports on
// serial / BLE are unchanged) and `set_theme` on either link is refused with
// ack ok:false err:"locked". Only the full-screen theme is frozen; the bottom strip
// (`stats`, `celebrate`, `strip`) and `set_mode` work exactly as before.
//
// `glow` (protocol section "屏幕闪光") is a third, independent layer: a <= 1 s white
// overlay on lv_layer_top that restores the pixels underneath exactly, so it takes
// no handshake, is not blocked by the screen lock, and may run while a
// will_change/changed pair is still open.
#include "app_state.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bsp_audio.h"
#include "bsp_battery.h"
#include "bsp_button.h"
#include "bsp_display.h"
#include "bsp_i2c.h"
#include "esp_log.h"
#include "esp_sleep.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "sdkconfig.h"

#include "app_events.h"
#include "audio/cues.h"
#include "card_types.h"
#include "link/ble_nus.h"
#include "link/proto.h"
#include "link/serial_link.h"
#include "power/power_policy.h"
#include "store/stats_rules.h"
#include "store/stats_store.h"
#include "ui/ui_flip.h"
#include "ui/ui_glow.h"
#include "ui/ui_screens.h"

static const char *TAG = "app";

#ifdef CONFIG_CARD_SCREEN_LOCK
#define SCREEN_LOCKED 1
#else
#define SCREEN_LOCKED 0
#endif

#define LVGL_LOCK_MS        500
#define ACK_TIMEOUT_MS      300
#define HEAP_FLOOR_BYTES    (80 * 1024)
#define BATTERY_SERIAL_S    30
#define BATTERY_BLE_S       60
#define DEFERRED_MAX        8
#define STRIP_WATCHDOG_S    (15 * 60)   // a forgotten `strip` override restores itself

static const int REGION_FULL[4]  = { 0, 0, CARD_SCREEN_W, CARD_SCREEN_H };
static const int REGION_STRIP[4] = { 0, CARD_STRIP_Y, CARD_SCREEN_W, CARD_STRIP_H };

static QueueHandle_t s_queue;
static esp_timer_handle_t s_tick;
static esp_timer_handle_t s_strip_wd;   // one-shot: clears a stale `strip` override

static struct {
    card_mode_t mode;
    char theme[CARD_THEME_ID_MAX];
    card_stats_t stats;
    char followers_text[16];
    char strip_override[CARD_STRIP_TEXT_MAX];   // "" = strip shows followers_text
    uint32_t boot;
    bool ble_connected;
    bool ble_subscribed;
    bool usb;
    uint32_t seconds;
    uint32_t seq;                       // will_change id counter
    bool flip_pending;                  // `changed` owed after the running flip
    char pending_id[PROTO_ID_MAX];
    app_event_t deferred[DEFERRED_MAX]; // events parked during an ack wait
    int n_deferred;
} s;

// ---------------------------------------------------------------------------
// Event queue (declared in app_events.h)
// ---------------------------------------------------------------------------
bool app_events_post(const app_event_t *ev)
{
    if (!s_queue) return false;
    return xQueueSend(s_queue, ev, 0) == pdTRUE;
}

bool app_events_post_line(app_ev_src_t src, const char *text, size_t len)
{
    if (!s_queue || len == 0 || len > PROTO_LINE_MAX) return false;
    char *copy = malloc(len + 1);
    if (!copy) return false;
    memcpy(copy, text, len);
    copy[len] = '\0';
    app_event_t ev = { .src = src, .kind = EV_LINE };
    ev.u.line.text = copy;
    ev.u.line.len = (uint16_t)len;
    if (xQueueSend(s_queue, &ev, 0) != pdTRUE) {
        free(copy);
        return false;
    }
    return true;
}

static void event_release(app_event_t *ev)
{
    if (ev->kind == EV_LINE) {
        free(ev->u.line.text);
        ev->u.line.text = NULL;
    }
}

// ---------------------------------------------------------------------------
// Transport helpers
// ---------------------------------------------------------------------------
static void send_serial(const char *json, int len)
{
    if (len > 0) serial_link_write_line(json, (size_t)len);
}

static void send_ble(const char *json, int len)
{
    if (len > 0 && s.ble_subscribed) ble_nus_send_line(json, (size_t)len);
}

static void send_to(app_ev_src_t src, const char *json, int len)
{
    if (src == EV_SRC_BLE) send_ble(json, len);
    else send_serial(json, len);
}

static void ack(app_ev_src_t src, const proto_msg_t *m, bool ok, const char *err, const char *theme)
{
    if (!m->has_id) return;   // commands without an id are not acknowledged
    char line[PROTO_LINE_MAX + 1];
    send_to(src, line, proto_format_ack(line, sizeof(line), m->id, ok, err, theme));
}

// Applied backlight percent for `hello` / `battery` (255 = nothing applied yet -> report 100).
static int backlight_percent(void)
{
    int p = power_policy_current().percent;
    return p > 100 ? 100 : p;
}

static void send_hello(app_ev_src_t src)
{
    char line[PROTO_LINE_MAX + 1];
    const proto_hello_t h = {
        .fw = CARD_FW_VERSION, .boot = s.boot, .mode = s.mode, .theme = s.theme, .stats = s.stats,
        .soc = bsp_battery_soc(), .mv = bsp_battery_mv(), .ble_connected = s.ble_connected,
        .heap = esp_get_free_heap_size(), .backlight = backlight_percent(),
        .screen_width_mm = CONFIG_CARD_SCREEN_WIDTH_MM,
    };
    send_to(src, line, proto_format_hello(line, sizeof(line), &h));
}

static uint32_t now_ms(void) { return (uint32_t)(esp_timer_get_time() / 1000); }

static void apply_power(void)
{
    power_policy_apply(s.mode == CARD_MODE_AR, s.usb, now_ms());
}

// ---------------------------------------------------------------------------
// AR handshake: will_change -> ack (<= 300 ms) with other events deferred
// ---------------------------------------------------------------------------
static void defer(const app_event_t *ev)
{
    if (s.n_deferred < DEFERRED_MAX) {
        s.deferred[s.n_deferred++] = *ev;
    } else {
        ESP_LOGW(TAG, "deferred queue full, dropping event kind=%d", ev->kind);
        app_event_t copy = *ev;
        event_release(&copy);
    }
}

static bool wait_for_ack(const char *id)
{
    TickType_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(ACK_TIMEOUT_MS);
    for (;;) {
        TickType_t now = xTaskGetTickCount();
        if ((int32_t)(deadline - now) <= 0) return false;
        app_event_t ev;
        if (xQueueReceive(s_queue, &ev, deadline - now) != pdTRUE) return false;
        if (ev.kind == EV_LINE && proto_is_ack_for(ev.u.line.text, ev.u.line.len, id)) {
            event_release(&ev);
            return true;
        }
        defer(&ev);
    }
}

// Returns true when a will_change was sent (caller repaints, then handshake_end).
static bool handshake_begin(const char *kind, const int region[4], char *id_out, size_t cap)
{
    if (s.mode != CARD_MODE_AR || !s.ble_subscribed) return false;
    if (s.flip_pending) {
        // A stat flip is still animating: close it out so the VP sees matched pairs.
        char line[PROTO_LINE_MAX + 1];
        send_ble(line, proto_format_changed(line, sizeof(line), s.pending_id, s.theme));
        s.flip_pending = false;
    }
    snprintf(id_out, cap, "w%lu", (unsigned long)++s.seq);
    char line[PROTO_LINE_MAX + 1];
    send_ble(line, proto_format_will_change(line, sizeof(line), id_out, kind, s.theme, region));
    if (!wait_for_ack(id_out)) ESP_LOGW(TAG, "will_change %s: no ack in %d ms", id_out, ACK_TIMEOUT_MS);
    return true;
}

static void handshake_end(const char *id)
{
    char line[PROTO_LINE_MAX + 1];
    send_ble(line, proto_format_changed(line, sizeof(line), id, s.theme));
}

// ---------------------------------------------------------------------------
// Screen mutations (the only LVGL callers, always under the lock)
// ---------------------------------------------------------------------------
static void on_flip_done(void *ctx)
{
    (void)ctx;
    const app_event_t ev = { .src = EV_SRC_TIMER, .kind = EV_FLIP_DONE };
    (void)app_events_post(&ev);   // LVGL task context: post only
}

static void repaint_theme(const char *theme)
{
    strncpy(s.theme, proto_theme_normalize(theme), sizeof(s.theme) - 1);
    char id[PROTO_ID_MAX];
    bool hs = handshake_begin("theme", REGION_FULL, id, sizeof(id));
    if (bsp_lvgl_lock(LVGL_LOCK_MS)) {
        ui_screens_set_theme(s.theme);
        ui_screens_refresh_now();
        bsp_lvgl_unlock();
    } else {
        ESP_LOGE(TAG, "LVGL lock timeout (theme)");
    }
    if (hs) handshake_end(id);
}

// What the bottom strip shows right now: the `strip` override while one is active,
// otherwise the follower count.
static const char *strip_text_now(void)
{
    return s.strip_override[0] ? s.strip_override : s.followers_text;
}

// Flips the strip label to `text` (the only thing that repaints [0,272,240,48]).
static void flip_strip(const char *text)
{
    char id[PROTO_ID_MAX];
    bool hs = handshake_begin("stat", REGION_STRIP, id, sizeof(id));
    bool started = false;
    if (bsp_lvgl_lock(LVGL_LOCK_MS)) {
        ui_flip_to(ui_screens_followers_label(), text, on_flip_done, NULL);
        started = true;
        bsp_lvgl_unlock();
    } else {
        ESP_LOGE(TAG, "LVGL lock timeout (flip)");
    }
    if (hs) {
        if (started) {
            s.flip_pending = true;
            strncpy(s.pending_id, id, sizeof(s.pending_id) - 1);
        } else {
            handshake_end(id);
        }
    }
}

static void enter_mode(card_mode_t mode)
{
    // Every mode command / BLE edge re-applies CONFIG_CARD_AR_BACKLIGHT_PERCENT: a
    // `backlight` level set during an AR session lives only for that session.
    power_policy_reset_ar_percent();
    if (mode == s.mode) { apply_power(); return; }
    s.mode = mode;
    ESP_LOGI(TAG, "mode -> %s", mode == CARD_MODE_AR ? "ar" : "idle");
    // Idle -> AR happens before the Vision Pro starts tracking: repaint directly.
    if (bsp_lvgl_lock(LVGL_LOCK_MS)) {
        ui_screens_set_quiet(mode == CARD_MODE_AR);
        ui_screens_set_dot(mode == CARD_MODE_AR ? UI_DOT_BLE : (s.usb ? UI_DOT_USB : UI_DOT_NONE));
        ui_screens_refresh_now();
        bsp_lvgl_unlock();
    }
    apply_power();
}

static void update_idle_dot(void)
{
    static ui_dot_t applied = UI_DOT_NONE;
    if (s.mode == CARD_MODE_AR) return;   // frozen in AR: no unsolicited repaint
    ui_dot_t want = s.usb ? UI_DOT_USB : UI_DOT_NONE;
    if (want == applied) return;
    if (bsp_lvgl_lock(LVGL_LOCK_MS)) {
        ui_screens_set_dot(want);
        bsp_lvgl_unlock();
        applied = want;
    }
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// `strip` override (protocol section "底条覆盖")
// ---------------------------------------------------------------------------
static void strip_wd_disarm(void)
{
    if (s_strip_wd) (void)esp_timer_stop(s_strip_wd);   // ESP_ERR_INVALID_STATE = not running
}

static void strip_wd_arm(void)
{
    if (!s_strip_wd) return;
    strip_wd_disarm();   // start_once refuses a running timer
    esp_err_t e = esp_timer_start_once(s_strip_wd, (uint64_t)STRIP_WATCHDOG_S * 1000000ULL);
    if (e != ESP_OK) ESP_LOGW(TAG, "strip watchdog not armed: %s", esp_err_to_name(e));
}

static void strip_set_override(const char *text)
{
    bool same = strcmp(strip_text_now(), text) == 0;
    strncpy(s.strip_override, text, sizeof(s.strip_override) - 1);
    s.strip_override[sizeof(s.strip_override) - 1] = '\0';
    strip_wd_arm();
    if (!same) flip_strip(s.strip_override);   // identical pixels: no will_change/changed pair
}

// Back to the follower count (which `stats` kept up to date silently meanwhile).
static void strip_restore_followers(void)
{
    if (!s.strip_override[0]) return;
    bool same = strcmp(s.strip_override, s.followers_text) == 0;
    s.strip_override[0] = '\0';
    strip_wd_disarm();
    if (!same) flip_strip(s.followers_text);
}

static void apply_stats(const card_stats_t *incoming, bool forward)
{
    s.stats = *incoming;
    stats_store_save_stats(&s.stats);
    char text[sizeof(s.followers_text)];
    stats_format_followers(text, sizeof(text), s.stats.followers);
    if (strcmp(text, s.followers_text) != 0) {
        strcpy(s.followers_text, text);
        // Under a `strip` override the strip belongs to the override: update the
        // stored text silently and let the restore show it.
        if (!s.strip_override[0]) flip_strip(s.followers_text);
    }
    if (forward) {
        char line[PROTO_LINE_MAX + 1];
        send_ble(line, proto_format_stats(line, sizeof(line), &s.stats));
    }
}

static void enter_deep_sleep(void)
{
    ESP_LOGW(TAG, "sleep: entering deep sleep (power button / reset wakes)");
    vTaskDelay(pdMS_TO_TICKS(200));   // let the ack leave the USB FIFO
    ble_nus_stop();
    // Upstream demo_low_power.c order: CW2017 -> ES8311 -> I2S pins -> I2C pins -> LCD.
    if (bsp_battery_sleep() != ESP_OK) ESP_LOGW(TAG, "CW2017 suspend failed");
    if (bsp_audio_sleep() != ESP_OK) ESP_LOGW(TAG, "ES8311 suspend failed");
    if (bsp_audio_prepare_deep_sleep() != ESP_OK) ESP_LOGW(TAG, "I2S release failed");
    if (bsp_i2c_prepare_deep_sleep() != ESP_OK) ESP_LOGW(TAG, "I2C release failed");
    if (!bsp_lvgl_lock(1000)) {
        ESP_LOGE(TAG, "cannot stop LVGL flushes; restarting instead");
        esp_restart();
    }
    if (bsp_display_prepare_deep_sleep() != ESP_OK) ESP_LOGW(TAG, "LCD suspend failed");
    esp_deep_sleep_start();
    esp_restart();   // not reached
}

static void handle_line(app_ev_src_t src, const char *text, size_t len)
{
    proto_msg_t m;
    if (!proto_parse(text, len, &m)) {
        ESP_LOGD(TAG, "ignored non-protocol line");
        return;
    }
    char line[PROTO_LINE_MAX + 1];
    switch (m.type) {
    case PROTO_HELLO:
        if (src == EV_SRC_SERIAL) serial_link_set_json_logs(m.mute_logs);
        send_hello(src);
        ack(src, &m, true, NULL, NULL);
        break;

    case PROTO_STATS:
        if (!m.stats_valid) { ack(src, &m, false, "stats", NULL); break; }
        if (stats_rules_accept(&s.stats, &m.stats)) apply_stats(&m.stats, src == EV_SRC_SERIAL);
        ack(src, &m, true, NULL, NULL);   // stale ts: ignored but still ok
        break;

    case PROTO_CELEBRATE:
        power_policy_note_activity(now_ms());
        apply_power();
        cues_play(CUE_CELEBRATE);
        flip_strip(strip_text_now());   // the override, when one is up; else the followers
        if (src == EV_SRC_SERIAL) {
            send_ble(line, proto_format_celebrate(line, sizeof(line), m.delta, s.stats.followers));
        }
        ack(src, &m, true, NULL, NULL);
        break;

    case PROTO_SET_THEME:
        // Screen lock: refuse before anything else, so neither the screen nor the
        // backlight policy moves. No "theme" field in the ack: nothing changed.
        if (SCREEN_LOCKED) { ack(src, &m, false, "locked", NULL); break; }
        if (!m.theme_valid) { ack(src, &m, false, "theme", NULL); break; }
        power_policy_note_activity(now_ms());
        apply_power();
        if (strcmp(m.theme, s.theme) != 0) {
            repaint_theme(m.theme);
            stats_store_save_theme(s.theme);
        }
        ack(src, &m, true, NULL, s.theme);
        break;

    case PROTO_SET_MODE:
        if (!m.mode_valid) { ack(src, &m, false, "mode", NULL); break; }
        enter_mode(m.mode);
        ack(src, &m, true, NULL, NULL);
        break;

    case PROTO_PLAY_CUE: {
        cue_id_t cue;
        if (!cues_id_from_name(m.cue, &cue)) { ack(src, &m, false, "cue", NULL); break; }
        bool queued = cues_play(cue);
        ack(src, &m, queued, queued ? NULL : "audio", NULL);
        break;
    }

    case PROTO_BACKLIGHT:
        if (m.percent < 0) { ack(src, &m, false, "percent", NULL); break; }
        // AR: set the level for this AR session (sticky across button presses).
        // Idle: the battery override, cleared by the next activity.
        if (s.mode == CARD_MODE_AR) power_policy_set_ar_percent(m.percent);
        else                        power_policy_set_override(m.percent);
        apply_power();
        ack(src, &m, true, NULL, NULL);
        break;

    case PROTO_CMD:
        if (!m.cmd[0]) { ack(src, &m, false, "cmd", NULL); break; }
        if (!s.ble_subscribed) { ack(src, &m, false, "ble", NULL); break; }
        send_ble(m.cmd, (int)strlen(m.cmd));
        ack(src, &m, true, NULL, NULL);
        break;

    case PROTO_STRIP:
        // No "text" = restore; bad text = err "glyph" and the strip is left alone.
        if (m.strip_has_text && !m.strip_valid) { ack(src, &m, false, "glyph", NULL); break; }
        if (m.strip_has_text) strip_set_override(m.strip_text);
        else                  strip_restore_followers();
        ack(src, &m, true, NULL, NULL);
        break;

    case PROTO_GLOW: {
        // A transient overlay above everything: no will_change/changed (the pixels
        // come back unchanged, so the headset has nothing to re-learn), no theme
        // change (so SCREEN_LOCKED does not apply), no queueing (a second `glow`
        // restarts the first). The ack only says the command was understood; it
        // leaves long before the animation ends.
        bool started = false;
        if (bsp_lvgl_lock(LVGL_LOCK_MS)) {
            ui_glow_start(m.glow_kind, m.glow_ms);
            started = true;
            bsp_lvgl_unlock();
        } else {
            ESP_LOGE(TAG, "LVGL lock timeout (glow)");
        }
        ack(src, &m, started, started ? NULL : "lvgl", NULL);
        break;
    }

    case PROTO_SLEEP:
        ack(src, &m, true, NULL, NULL);
        enter_deep_sleep();
        break;

    case PROTO_PING:
        ack(src, &m, true, NULL, NULL);
        break;

    case PROTO_ACK:
        ESP_LOGD(TAG, "late ack %s", m.id);
        break;

    case PROTO_UNKNOWN:
    default:
        ack(src, &m, false, "unknown", NULL);
        break;
    }
}

static const char *btn_name(uint8_t btn)
{
    switch (btn) {
    case BSP_BTN_UP:   return "up";
    case BSP_BTN_DOWN: return "down";
    default:           return "ok";
    }
}

static void handle_button(uint8_t btn, uint8_t ev)
{
    power_policy_note_activity(now_ms());
    apply_power();
    const char *evname = ev == BSP_BTN_CLICK ? "click" : ev == BSP_BTN_LONG ? "long" : NULL;
    if (!evname) return;   // PRESS/DOUBLE only count as activity

#ifdef CONFIG_CARD_BUTTON_BLINK
    // AR mode has no local UI feedback at all, so a press is invisible on the card.
    // Answered with the backlight only: no repaint, no handshake, no change to the
    // reported level (see power_policy_blink). The blink runs toward the far end of
    // the range -- from the 85 % AR default it flashes UP to 100 for 120 ms, and only
    // a session already at 100 dips instead. This is the first thing the press does
    // after the debounce, so the response is immediate.
    if (s.mode == CARD_MODE_AR) power_policy_blink(now_ms());
#endif

    char line[PROTO_LINE_MAX + 1];
    int n = proto_format_button(line, sizeof(line), btn_name(btn), evname);
    if (s.mode == CARD_MODE_AR) {
        send_ble(line, n);   // AR: no local feedback, BLE report only
        return;
    }
    send_serial(line, n);
    if (ev == BSP_BTN_CLICK && (btn == BSP_BTN_UP || btn == BSP_BTN_DOWN)) {
        // Screen lock: the press is still reported above, it just does not repaint.
        if (!SCREEN_LOCKED) {
            int idx = proto_theme_index(s.theme) + (btn == BSP_BTN_UP ? 1 : -1);
            repaint_theme(proto_theme_at(idx));
            stats_store_save_theme(s.theme);
        }
    } else if (ev == BSP_BTN_CLICK && btn == BSP_BTN_OK) {
        cues_play(CUE_CELEBRATE);
    } else if (ev == BSP_BTN_LONG && btn == BSP_BTN_OK) {
        ble_nus_readvertise();
        send_hello(EV_SRC_SERIAL);
    }
}

static void handle_tick(void)
{
    s.seconds++;
    s.usb = serial_link_usb_present();
    uint32_t heap = esp_get_free_heap_size();
    if (heap < HEAP_FLOOR_BYTES && s.seconds % 10 == 0) {
        ESP_LOGE(TAG, "heap low: %lu bytes (floor %u)", (unsigned long)heap, HEAP_FLOOR_BYTES);
    }
    apply_power();
    update_idle_dot();
    char line[PROTO_LINE_MAX + 1];
    if (s.seconds % BATTERY_SERIAL_S == 0) {
        send_serial(line, proto_format_battery_serial(line, sizeof(line), bsp_battery_soc(),
                                                      bsp_battery_mv(), s.usb, heap,
                                                      backlight_percent()));
    }
    if (s.seconds % BATTERY_BLE_S == 0 && s.ble_subscribed) {
        send_ble(line, proto_format_battery_ble(line, sizeof(line), bsp_battery_soc(),
                                                backlight_percent()));
    }
}

static void handle_event(app_event_t *ev)
{
    char line[PROTO_LINE_MAX + 1];
    switch (ev->kind) {
    case EV_BTN:
        handle_button(ev->u.btn.btn, ev->u.btn.ev);
        break;
    case EV_LINE:
        handle_line(ev->src, ev->u.line.text, ev->u.line.len);
        break;
    case EV_BLE_CONNECTED:
        s.ble_connected = true;
        s.ble_subscribed = false;
        enter_mode(CARD_MODE_AR);
        send_serial(line, proto_format_ble(line, sizeof(line), true));
        break;
    case EV_BLE_SUBSCRIBED:
        s.ble_subscribed = true;
        send_hello(EV_SRC_BLE);   // sent once notifications can actually be delivered
        break;
    case EV_BLE_DISCONNECTED:
        s.ble_connected = false;
        s.ble_subscribed = false;
        s.flip_pending = false;
        enter_mode(CARD_MODE_IDLE);
        strip_restore_followers();   // after the mode switch: the flip runs in idle style
        send_serial(line, proto_format_ble(line, sizeof(line), false));
        break;
    case EV_TICK:
        handle_tick();
        break;
    case EV_FLIP_DONE:
        if (s.flip_pending) {
            s.flip_pending = false;
            handshake_end(s.pending_id);
        }
        break;
    case EV_STRIP_TIMEOUT:
        // The one-shot is inactive once it has fired, so an active timer here means a
        // newer `strip{text}` re-armed it while this event was queued: that event is
        // stale and must not cut the fresh override short.
        if (s_strip_wd && esp_timer_is_active(s_strip_wd)) break;
        ESP_LOGI(TAG, "strip override expired after %d s", STRIP_WATCHDOG_S);
        strip_restore_followers();
        break;
    default:
        break;
    }
    event_release(ev);
}

static void drain_deferred(void)
{
    while (s.n_deferred > 0) {
        app_event_t batch[DEFERRED_MAX];
        int n = s.n_deferred;
        memcpy(batch, s.deferred, sizeof(app_event_t) * (size_t)n);
        s.n_deferred = 0;
        for (int i = 0; i < n; i++) handle_event(&batch[i]);
    }
}

static void app_task(void *arg)
{
    (void)arg;
    ESP_LOGI(TAG, "ready: mode=idle theme=%s followers=%s ble=%s", s.theme, s.followers_text,
             ble_nus_device_name());
    send_hello(EV_SRC_SERIAL);
    for (;;) {
        app_event_t ev;
        if (xQueueReceive(s_queue, &ev, portMAX_DELAY) != pdTRUE) continue;
        handle_event(&ev);
        drain_deferred();
    }
}

static void tick_cb(void *arg)
{
    (void)arg;
    const app_event_t ev = { .src = EV_SRC_TIMER, .kind = EV_TICK };
    (void)app_events_post(&ev);
}

static void strip_wd_cb(void *arg)
{
    (void)arg;
    const app_event_t ev = { .src = EV_SRC_TIMER, .kind = EV_STRIP_TIMEOUT };
    (void)app_events_post(&ev);   // esp_timer task context: post only
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------
esp_err_t app_state_init(void)
{
    s_queue = xQueueCreate(APP_EVENT_QUEUE_DEPTH, sizeof(app_event_t));
    if (!s_queue) return ESP_ERR_NO_MEM;
    s.mode = CARD_MODE_IDLE;
    (void)stats_store_init();
    stats_store_load(&s.stats, s.theme, sizeof(s.theme), &s.boot);
    if (SCREEN_LOCKED) {
        // Whatever NVS remembers, boot into the trained screen; nothing writes it back.
        strncpy(s.theme, proto_theme_normalize(CONFIG_CARD_DEFAULT_THEME), sizeof(s.theme) - 1);
        s.theme[sizeof(s.theme) - 1] = '\0';
        ESP_LOGI(TAG, "screen lock: theme %s", s.theme);
    }
    stats_format_followers(s.followers_text, sizeof(s.followers_text), s.stats.followers);
    power_policy_init(now_ms());
    return ESP_OK;
}

esp_err_t app_state_ui_init(void)
{
    if (!bsp_lvgl_lock(1000)) return ESP_ERR_TIMEOUT;
    ui_screens_create(s.theme, s.followers_text, false);
    bsp_lvgl_unlock();
    return ESP_OK;
}

esp_err_t app_state_start(void)
{
    s.usb = serial_link_usb_present();
    apply_power();
    const esp_timer_create_args_t targs = { .callback = tick_cb, .name = "card_tick" };
    esp_err_t e = esp_timer_create(&targs, &s_tick);
    if (e == ESP_OK) e = esp_timer_start_periodic(s_tick, 1000000ULL);
    if (e != ESP_OK) return e;
    const esp_timer_create_args_t wargs = { .callback = strip_wd_cb, .name = "card_strip_wd" };
    e = esp_timer_create(&wargs, &s_strip_wd);
    if (e != ESP_OK) return e;   // armed only while a `strip` override is up
    if (xTaskCreate(app_task, "card_app", 8192, NULL, 5, NULL) != pdPASS) return ESP_ERR_NO_MEM;
    return ESP_OK;
}
