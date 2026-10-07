// main/ui/ui_glow.h — transient "recognition scan" overlay drawn on `lv_layer_top()`,
// i.e. *above* the theme image, the strip container and the status dot, without
// touching any of them. The overlay object deletes itself when its animation ends,
// so LVGL repaints the area from what was underneath and the pixels come back
// exactly as they were:
//   - no `will_change` / `changed` handshake (the headset has nothing to re-learn),
//   - CONFIG_CARD_SCREEN_LOCK does not apply (no theme change is involved),
//   - the whole thing is over in CARD_GLOW_MS_MAX (1 s) at the very latest.
// Same call discipline as ui_flip: call with bsp_lvgl_lock() held, from app_state.c
// only. The animation itself then runs in the LVGL task.
#pragma once

#include <stdbool.h>

#include "card_types.h"

// Start a glow, deleting a running one first (restart semantics — never queued).
// `ms` is clamped to CARD_GLOW_MS_MIN..CARD_GLOW_MS_MAX.
void ui_glow_start(card_glow_kind_t kind, int ms);

// Drop a running overlay immediately; the pixels underneath are repainted on the
// next LVGL refresh. Safe to call when no glow is running.
void ui_glow_cancel(void);

bool ui_glow_active(void);
