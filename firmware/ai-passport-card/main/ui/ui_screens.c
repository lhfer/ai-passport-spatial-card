// main/ui/ui_screens.c — see ui_screens.h.
#include "ui/ui_screens.h"

#include <string.h>

#include "card_types.h"
#include "link/proto.h"

LV_IMAGE_DECLARE(theme_base);
LV_IMAGE_DECLARE(theme_neon_city);
LV_IMAGE_DECLARE(theme_data_nebula);
LV_FONT_DECLARE(font_digits_36);
LV_FONT_DECLARE(font_digits_20);

// Strip text colours. The Hub renders a dark, flat strip area into every theme image;
// tune these two constants together with hub/tools/render-screens.ts.
#define UI_IDLE_TEXT_COLOR   0xFFFFFF   // bright, high contrast
#define UI_AR_TEXT_COLOR     0x4F4F4F   // ~2.5:1 against black: visible up close, quiet for tracking
#define UI_DOT_BLE_COLOR     0x2F7BFF
#define UI_DOT_USB_COLOR     0x2FBF6F
#define UI_DOT_SIZE          4

static lv_obj_t *s_img;
static lv_obj_t *s_strip;
static lv_obj_t *s_label;
static lv_obj_t *s_dot;

static const lv_image_dsc_t *theme_image(const char *theme)
{
    switch (proto_theme_index(theme)) {
    case 1:  return &theme_neon_city;
    case 2:  return &theme_data_nebula;
    default: return &theme_base;
    }
}

static void apply_style(bool quiet)
{
    lv_obj_set_style_text_font(s_label, quiet ? &font_digits_20 : &font_digits_36, 0);
    lv_obj_set_style_text_color(s_label, lv_color_hex(quiet ? UI_AR_TEXT_COLOR : UI_IDLE_TEXT_COLOR), 0);
    lv_obj_center(s_label);
}

void ui_screens_create(const char *theme, const char *followers_text, bool quiet)
{
    lv_obj_t *scr = lv_screen_active();
    lv_obj_remove_style_all(scr);
    lv_obj_set_style_bg_color(scr, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
    lv_obj_remove_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    s_img = lv_image_create(scr);
    lv_obj_set_pos(s_img, 0, 0);
    lv_obj_set_size(s_img, CARD_SCREEN_W, CARD_SCREEN_H);
    lv_image_set_src(s_img, theme_image(theme));

    // Transparent clipping container: the label/animation cannot leave the strip.
    s_strip = lv_obj_create(scr);
    lv_obj_remove_style_all(s_strip);
    lv_obj_set_pos(s_strip, 0, CARD_STRIP_Y);
    lv_obj_set_size(s_strip, CARD_SCREEN_W, CARD_STRIP_H);
    lv_obj_remove_flag(s_strip, LV_OBJ_FLAG_SCROLLABLE);

    s_label = lv_label_create(s_strip);
    lv_label_set_text(s_label, followers_text ? followers_text : "0");
    apply_style(quiet);

    s_dot = lv_obj_create(s_strip);
    lv_obj_remove_style_all(s_dot);
    lv_obj_set_size(s_dot, UI_DOT_SIZE, UI_DOT_SIZE);
    lv_obj_set_pos(s_dot, CARD_SCREEN_W - 10, CARD_STRIP_H - 10);
    lv_obj_set_style_radius(s_dot, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_opa(s_dot, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(s_dot, lv_color_hex(UI_DOT_BLE_COLOR), 0);
    lv_obj_add_flag(s_dot, LV_OBJ_FLAG_HIDDEN);
}

void ui_screens_set_theme(const char *theme)
{
    if (s_img) lv_image_set_src(s_img, theme_image(theme));
}

void ui_screens_set_quiet(bool quiet)
{
    if (s_label) apply_style(quiet);
}

void ui_screens_set_dot(ui_dot_t dot)
{
    if (!s_dot) return;
    if (dot == UI_DOT_NONE) {
        lv_obj_add_flag(s_dot, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    lv_obj_set_style_bg_color(s_dot, lv_color_hex(dot == UI_DOT_BLE ? UI_DOT_BLE_COLOR : UI_DOT_USB_COLOR), 0);
    lv_obj_remove_flag(s_dot, LV_OBJ_FLAG_HIDDEN);
}

lv_obj_t *ui_screens_followers_label(void) { return s_label; }

void ui_screens_refresh_now(void) { lv_refr_now(NULL); }
