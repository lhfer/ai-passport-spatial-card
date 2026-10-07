// main/ui/ui_flip.h — text change animation for the bottom strip label: the old text
// slides down and fades out, the new text drops in from above (<= 800 ms). The
// label lives inside the clipped strip container, so pixels outside the bottom
// 48 px never change. Call with bsp_lvgl_lock() held. The completion callback
// runs in the LVGL task: it must only post an event, never touch LVGL or block.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "lvgl.h"

#define UI_FLIP_MS 600   // must stay <= 800 ms (handshake budget: 300 ms ack + flip < 3 s hold)

typedef void (*ui_flip_done_cb_t)(void *ctx);

void ui_flip_to(lv_obj_t *label, const char *text, ui_flip_done_cb_t done, void *ctx);
bool ui_flip_active(void);
