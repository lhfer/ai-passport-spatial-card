// main/app_state.h — the card state machine: mode {idle, ar} x theme x stats.
// Owns the event queue and the app task; the only module that drives the UI
// (always under bsp_lvgl_lock) and that talks to both transports. Command
// handling is transport-agnostic: an ack goes back to whichever link delivered
// the command.
#pragma once

#include "esp_err.h"

// 1) before any producer exists: queue + NVS-backed state.
esp_err_t app_state_init(void);
// 2) after bsp_lvgl_init(): builds the screen under the LVGL lock.
esp_err_t app_state_ui_init(void);
// 3) after the links are up: starts the 1 s heartbeat and the app task
//    (first action: `hello` on serial).
esp_err_t app_state_start(void);
