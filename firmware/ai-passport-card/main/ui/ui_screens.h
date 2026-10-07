// main/ui/ui_screens.h — the one and only screen: a full-screen flash-resident theme
// image (never copied to RAM), a follower-count label inside the bottom 48 px
// dynamic strip (clipped by a transparent container so nothing can draw outside
// [0,272,240,48]), and a 4 px status dot in the strip corner.
//   idle style: 36 px bright digits readable across a room
//   ar   style: 20 px low-contrast "quiet" digits (~2.5:1 on a dark strip)
// Every function must be called with bsp_lvgl_lock() held; only app_state.c calls them.
#pragma once

#include <stdbool.h>

#include "lvgl.h"

typedef enum { UI_DOT_NONE = 0, UI_DOT_BLE, UI_DOT_USB } ui_dot_t;

void ui_screens_create(const char *theme, const char *followers_text, bool quiet);
void ui_screens_set_theme(const char *theme);        // lv_image_set_src on the flash image
void ui_screens_set_quiet(bool quiet);               // idle <-> ar digit style
void ui_screens_set_dot(ui_dot_t dot);
lv_obj_t *ui_screens_followers_label(void);          // for ui_flip
void ui_screens_refresh_now(void);                   // lv_refr_now(NULL): flush before `changed`
