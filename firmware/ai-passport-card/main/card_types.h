// main/card_types.h — plain data types shared by every module (no ESP-IDF/LVGL).
#pragma once

#include <stdbool.h>
#include <stdint.h>

#define CARD_FW_VERSION "0.2.1"   // 0.2.0 = the `glow` command exists (docs/protocol.md);
                                  // 0.2.1 = AR backlight 85 % + the button blink on by default

// Stats object, isomorphic on every link (docs/protocol.md).
typedef struct {
    int32_t followers;
    int32_t likes;
    int32_t notes;
    int32_t delta;   // net follower gain since the previous sample, >= 0
    int64_t ts;      // Unix seconds; newest wins
} card_stats_t;

// Seed values from assets/card/card.json (schema 2) used until the Hub pushes stats.
#define CARD_SEED_FOLLOWERS 4313
#define CARD_SEED_LIKES     44000
#define CARD_SEED_NOTES     0

typedef enum {
    CARD_MODE_IDLE = 0,   // no BLE central: big bright digits, local button feedback
    CARD_MODE_AR,         // BLE central connected: pixel-static screen, quiet digits
} card_mode_t;

#define CARD_THEME_COUNT 3
#define CARD_THEME_ID_MAX 16   // longest id "data-nebula" + NUL

// Screen geometry (assets/card/card.json device section).
#define CARD_SCREEN_W        240
#define CARD_SCREEN_H        320
#define CARD_STRIP_H         48                       // dynamic strip at the bottom
#define CARD_STRIP_Y         (CARD_SCREEN_H - CARD_STRIP_H)

// Text the strip can show (follower count, or a `strip` override such as "♥1825").
// Glyph set: 0-9 . + - k space 万 ▲ ▼ ♥ (docs/protocol.md "底条覆盖"); the three-byte
// ones make the worst case 12 * 3 + NUL = 37 bytes.
#define CARD_STRIP_MAX_CODEPOINTS 12
#define CARD_STRIP_TEXT_MAX       40

// Screen glow (docs/protocol.md 「屏幕闪光 glow」): a short white overlay drawn on
// top of everything for the Vision Pro's "recognition scan" moment. Transient by
// construction — the pixels underneath are restored exactly — so it needs no
// will_change/changed handshake and is not affected by CONFIG_CARD_SCREEN_LOCK.
typedef enum {
    CARD_GLOW_SWEEP = 0,   // 240 x 24 bar with a soft alpha edge, bottom -> top
    CARD_GLOW_FLASH,       // full-screen white, fades in then out
} card_glow_kind_t;

#define CARD_GLOW_MS_MIN      50
#define CARD_GLOW_MS_MAX      1000
#define CARD_GLOW_MS_DEFAULT  300
