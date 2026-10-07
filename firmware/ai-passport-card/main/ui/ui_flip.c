// main/ui/ui_flip.c — see ui_flip.h.
#include "ui/ui_flip.h"

#include <string.h>

#include "card_types.h"

#define FLIP_STEPS   1000
#define FLIP_SHIFT   14      // px of vertical travel, well inside the 48 px strip

// Holds the longest thing the strip can show: a 12 code point `strip` override
// (CARD_STRIP_TEXT_MAX), so a multi-byte glyph is never cut in half by the copy.
static char s_next[CARD_STRIP_TEXT_MAX];
static bool s_swapped;
static bool s_active;
static ui_flip_done_cb_t s_done;
static void *s_ctx;

static void exec_cb(void *var, int32_t v)
{
    lv_obj_t *label = var;
    if (v < FLIP_STEPS / 2) {
        // phase 1: old text slides down and fades
        int32_t k = v * 2;                                   // 0..1000
        lv_obj_set_style_translate_y(label, (FLIP_SHIFT * k) / FLIP_STEPS, 0);
        lv_obj_set_style_opa(label, (lv_opa_t)(LV_OPA_COVER - (LV_OPA_COVER * k) / FLIP_STEPS), 0);
    } else {
        if (!s_swapped) {
            s_swapped = true;
            lv_label_set_text(label, s_next);
        }
        // phase 2: new text drops in from above and fades in
        int32_t k = (v - FLIP_STEPS / 2) * 2;                // 0..1000
        lv_obj_set_style_translate_y(label, -FLIP_SHIFT + (FLIP_SHIFT * k) / FLIP_STEPS, 0);
        lv_obj_set_style_opa(label, (lv_opa_t)((LV_OPA_COVER * k) / FLIP_STEPS), 0);
    }
}

static void completed_cb(lv_anim_t *a)
{
    lv_obj_t *label = a->var;
    if (!s_swapped) lv_label_set_text(label, s_next);
    lv_obj_set_style_translate_y(label, 0, 0);
    lv_obj_set_style_opa(label, LV_OPA_COVER, 0);
    s_active = false;
    if (s_done) s_done(s_ctx);
}

void ui_flip_to(lv_obj_t *label, const char *text, ui_flip_done_cb_t done, void *ctx)
{
    if (!label || !text) return;
    if (s_active) {
        // Abort the running flip: settle on its target text, then start the new one.
        lv_anim_delete(label, exec_cb);
        if (!s_swapped) lv_label_set_text(label, s_next);
        lv_obj_set_style_translate_y(label, 0, 0);
        lv_obj_set_style_opa(label, LV_OPA_COVER, 0);
    }
    strncpy(s_next, text, sizeof(s_next) - 1);
    s_next[sizeof(s_next) - 1] = '\0';
    s_swapped = false;
    s_done = done;
    s_ctx = ctx;
    s_active = true;

    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, label);
    lv_anim_set_values(&a, 0, FLIP_STEPS);
    lv_anim_set_duration(&a, UI_FLIP_MS);
    lv_anim_set_path_cb(&a, lv_anim_path_ease_in_out);
    lv_anim_set_exec_cb(&a, exec_cb);
    lv_anim_set_completed_cb(&a, completed_cb);
    lv_anim_start(&a);
}

bool ui_flip_active(void) { return s_active; }
