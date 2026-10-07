// main/ui/ui_glow.c — see ui_glow.h.
#include "ui/ui_glow.h"

#include "lvgl.h"

#define GLOW_STEPS       1000                  // animation variable, mapped per kind
#define GLOW_BAR_H       24                    // sweep bar height
#define GLOW_BAND_H      (GLOW_BAR_H / 3)      // 8 px: fade in / solid / fade out
#define GLOW_FLASH_RISE  400                   // 40 % of GLOW_STEPS: 0 -> 255, rest 255 -> 0

// The overlay currently on lv_layer_top(), or NULL. Only ever touched with the LVGL
// lock held (app task) or from the LVGL task itself (the animation callbacks).
static lv_obj_t *s_obj;
static card_glow_kind_t s_kind;

// One 240 x 8 slice of the sweep bar. CONFIG_LV_GRADIENT_MAX_STOPS is 2, so a single
// object cannot ramp 0 -> 255 -> 0; the built-in two-stop gradient (bg_main_opa at
// the top edge, bg_grad_opa at the bottom edge, both stops white) does one edge each
// and three stacked slices give the soft-edged bar the protocol describes.
static void glow_band(lv_obj_t *parent, int32_t y, lv_opa_t top_opa, lv_opa_t bottom_opa)
{
    lv_obj_t *b = lv_obj_create(parent);
    if (!b) return;
    lv_obj_remove_style_all(b);   // the default theme adds radius/border/padding
    lv_obj_remove_flag(b, LV_OBJ_FLAG_SCROLLABLE | LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_pos(b, 0, y);
    lv_obj_set_size(b, CARD_SCREEN_W, GLOW_BAND_H);
    lv_obj_set_style_bg_color(b, lv_color_white(), 0);
    lv_obj_set_style_bg_grad_color(b, lv_color_white(), 0);
    if (top_opa == bottom_opa) {
        lv_obj_set_style_bg_opa(b, top_opa, 0);
        return;
    }
    lv_obj_set_style_bg_opa(b, LV_OPA_COVER, 0);   // the gradient supplies the alpha
    lv_obj_set_style_bg_grad_dir(b, LV_GRAD_DIR_VER, 0);
    lv_obj_set_style_bg_main_opa(b, top_opa, 0);
    lv_obj_set_style_bg_grad_opa(b, bottom_opa, 0);
}

static void glow_exec_cb(void *var, int32_t v)
{
    lv_obj_t *obj = var;
    if (s_kind == CARD_GLOW_FLASH) {
        int32_t opa = v < GLOW_FLASH_RISE
                          ? (LV_OPA_COVER * v) / GLOW_FLASH_RISE
                          : (LV_OPA_COVER * (GLOW_STEPS - v)) / (GLOW_STEPS - GLOW_FLASH_RISE);
        lv_obj_set_style_bg_opa(obj, (lv_opa_t)opa, 0);
        return;
    }
    // sweep: y travels CARD_SCREEN_H -> -GLOW_BAR_H (fully off both edges)
    lv_obj_set_y(obj, CARD_SCREEN_H - ((CARD_SCREEN_H + GLOW_BAR_H) * v) / GLOW_STEPS);
}

// LVGL task context. lv_anim_delete() (the cancel path) does not call this, so the
// static pointer is cleared by whoever removed the object.
static void glow_completed_cb(lv_anim_t *a)
{
    lv_obj_t *obj = a->var;
    if (obj == s_obj) s_obj = NULL;
    lv_obj_delete_async(obj);   // never delete an object from inside its own callback
}

void ui_glow_start(card_glow_kind_t kind, int ms)
{
    ui_glow_cancel();   // restart semantics: a second glow replaces the first
    if (ms < CARD_GLOW_MS_MIN) ms = CARD_GLOW_MS_MIN;
    if (ms > CARD_GLOW_MS_MAX) ms = CARD_GLOW_MS_MAX;
    s_kind = (kind == CARD_GLOW_FLASH) ? CARD_GLOW_FLASH : CARD_GLOW_SWEEP;

    lv_obj_t *top = lv_layer_top();
    if (!top) return;
    lv_obj_t *obj = lv_obj_create(top);
    if (!obj) return;
    lv_obj_remove_style_all(obj);
    lv_obj_remove_flag(obj, LV_OBJ_FLAG_SCROLLABLE | LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(obj, LV_OBJ_FLAG_IGNORE_LAYOUT);

    if (s_kind == CARD_GLOW_FLASH) {
        lv_obj_set_pos(obj, 0, 0);
        lv_obj_set_size(obj, CARD_SCREEN_W, CARD_SCREEN_H);
        lv_obj_set_style_bg_color(obj, lv_color_white(), 0);
        lv_obj_set_style_bg_opa(obj, LV_OPA_TRANSP, 0);
    } else {
        lv_obj_set_pos(obj, 0, CARD_SCREEN_H);   // just below the screen
        lv_obj_set_size(obj, CARD_SCREEN_W, GLOW_BAR_H);
        glow_band(obj, 0,                   LV_OPA_TRANSP, LV_OPA_COVER);
        glow_band(obj, GLOW_BAND_H,         LV_OPA_COVER,  LV_OPA_COVER);
        glow_band(obj, 2 * GLOW_BAND_H,     LV_OPA_COVER,  LV_OPA_TRANSP);
    }
    s_obj = obj;

    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, obj);   // the animated object is the var, so deleting it kills the anim
    lv_anim_set_values(&a, 0, GLOW_STEPS);
    lv_anim_set_duration(&a, (uint32_t)ms);
    lv_anim_set_path_cb(&a, s_kind == CARD_GLOW_FLASH ? lv_anim_path_linear
                                                      : lv_anim_path_ease_in_out);
    lv_anim_set_exec_cb(&a, glow_exec_cb);
    lv_anim_set_completed_cb(&a, glow_completed_cb);
    lv_anim_start(&a);
}

void ui_glow_cancel(void)
{
    lv_obj_t *obj = s_obj;
    if (!obj) return;
    s_obj = NULL;
    lv_anim_delete(obj, glow_exec_cb);   // no completed_cb on an explicit delete
    lv_obj_delete(obj);                  // children and any leftover anim go with it
}

bool ui_glow_active(void) { return s_obj != NULL; }
