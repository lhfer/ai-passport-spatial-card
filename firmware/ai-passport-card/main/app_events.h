// main/app_events.h — the single FreeRTOS event queue feeding the app task.
// Producers (button callback, serial reader, NimBLE host task, esp_timer, LVGL
// animation callback) only enqueue; app_state.c owns the queue and consumes it.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    EV_SRC_BTN = 0,
    EV_SRC_SERIAL,
    EV_SRC_BLE,
    EV_SRC_TIMER,
} app_ev_src_t;

typedef enum {
    EV_BTN = 0,           // src BTN: payload btn
    EV_LINE,              // src SERIAL|BLE: payload line (heap copy, consumer frees)
    EV_BLE_CONNECTED,     // src BLE
    EV_BLE_SUBSCRIBED,    // src BLE: central enabled TX notifications
    EV_BLE_DISCONNECTED,  // src BLE
    EV_TICK,              // src TIMER: 1 s heartbeat
    EV_FLIP_DONE,         // src TIMER: strip flip animation completed (from LVGL task)
    EV_STRIP_TIMEOUT,     // src TIMER: `strip` override watchdog expired -> restore followers
} app_ev_kind_t;

typedef struct {
    app_ev_src_t src;
    app_ev_kind_t kind;
    union {
        struct { uint8_t btn; uint8_t ev; } btn;       // bsp_btn_t / bsp_btn_ev_t
        struct { char *text; uint16_t len; } line;      // NUL-terminated JSON line
    } u;
} app_event_t;

#define APP_EVENT_QUEUE_DEPTH 16

// Non-blocking; returns false when the queue is full (event dropped).
bool app_events_post(const app_event_t *ev);
// Copies the line to the heap and posts EV_LINE; false on drop.
bool app_events_post_line(app_ev_src_t src, const char *text, size_t len);
