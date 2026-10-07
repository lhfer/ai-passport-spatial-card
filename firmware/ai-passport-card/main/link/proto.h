// main/link/proto.h — Spatial Card line protocol v1 (docs/protocol.md).
// Pure functions shared by the serial and BLE transports: parse one JSON line into
// a proto_msg_t and format outgoing lines. No ESP-IDF or LVGL dependency, so the
// host tests in tests/ compile this file unchanged (only cJSON + libc).
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "card_types.h"

#define PROTO_LINE_MAX  512   // bytes per line, excluding the '\n'
#define PROTO_ID_MAX    24    // command id, incl. NUL
#define PROTO_CUE_MAX   12
#define PROTO_CMD_MAX   256   // re-serialized {"t":"cmd",...} forwarded to the VP

typedef enum {
    PROTO_INVALID = 0,   // not a JSON object or no string "t" -> ignore silently
    PROTO_UNKNOWN,       // well-formed but unhandled "t" -> ack ok:false err:"unknown"
    PROTO_HELLO,
    PROTO_STATS,
    PROTO_CELEBRATE,
    PROTO_SET_THEME,
    PROTO_SET_MODE,
    PROTO_PLAY_CUE,
    PROTO_BACKLIGHT,
    PROTO_CMD,
    PROTO_STRIP,
    PROTO_GLOW,
    PROTO_SLEEP,
    PROTO_PING,
    PROTO_ACK,
} proto_type_t;

typedef struct {
    proto_type_t type;
    bool has_id;
    char id[PROTO_ID_MAX];
    // hello
    bool mute_logs;
    // stats: valid only when followers and ts are present and non-negative
    bool stats_valid;
    card_stats_t stats;
    // celebrate
    int32_t delta;
    // set_theme: theme_valid = a string was given; theme = normalized id (unknown -> "base")
    bool theme_valid;
    char theme[CARD_THEME_ID_MAX];
    // set_mode
    bool mode_valid;
    card_mode_t mode;
    // play_cue
    char cue[PROTO_CUE_MAX];
    // backlight: 0..100, or -1 when missing/out of range
    int percent;
    // cmd: the original object without "id", ready to forward verbatim; "" if no "c"
    char cmd[PROTO_CMD_MAX];
    // strip: strip_has_text = a "text" key was given (any type; absent = restore the
    // follower count). strip_valid = it is a string that passes proto_strip_text_valid,
    // i.e. strip_text is safe to show. has_text && !valid -> ack ok:false err:"glyph".
    bool strip_has_text;
    bool strip_valid;
    char strip_text[CARD_STRIP_TEXT_MAX];
    // glow: always usable values. glow_ms is CARD_GLOW_MS_MIN..CARD_GLOW_MS_MAX
    // (missing, non-numeric or out of range -> CARD_GLOW_MS_DEFAULT); an unknown
    // or missing "kind" is CARD_GLOW_SWEEP. Only meaningful for PROTO_GLOW.
    int glow_ms;
    card_glow_kind_t glow_kind;
    // ack
    bool ack_ok;
} proto_msg_t;

// Parse one line (no trailing newline required). Returns false for PROTO_INVALID.
bool proto_parse(const char *line, size_t len, proto_msg_t *out);

// True when the line is {"t":"ack","id":<id>,...}. Used by the will_change wait.
bool proto_is_ack_for(const char *line, size_t len, const char *id);

// Bottom-strip text check (docs/protocol.md "底条覆盖"): 1..CARD_STRIP_MAX_CODEPOINTS
// code points, every one of them in the strip font's glyph set
// (0-9 . + - k space 万 ▲ ▼ ♥). Malformed UTF-8 is rejected.
bool proto_strip_text_valid(const char *text);

// Theme helpers. Unknown or NULL ids map to "base" (protocol: other world ids -> base).
const char *proto_theme_normalize(const char *theme);
bool proto_theme_known(const char *theme);
int proto_theme_index(const char *theme);          // 0..2 after normalization
const char *proto_theme_at(int index);             // index wraps modulo CARD_THEME_COUNT

// Formatters write a single JSON object without the trailing '\n'.
// They return the length, or -1 when the buffer was too small (buffer is then
// NUL-terminated but truncated: do not send it).
typedef struct {
    const char *fw;
    uint32_t boot;
    card_mode_t mode;
    const char *theme;
    card_stats_t stats;
    int soc;                    // -1 when unavailable
    int mv;                     // -1 when unavailable
    bool ble_connected;
    uint32_t heap;
    int backlight;              // applied backlight percent 0..100 (power_policy_current())
    const char *screen_width_mm; // numeric string from Kconfig, or NULL to omit
} proto_hello_t;

int proto_format_hello(char *buf, size_t cap, const proto_hello_t *h);
int proto_format_ack(char *buf, size_t cap, const char *id, bool ok, const char *err,
                     const char *theme);
int proto_format_button(char *buf, size_t cap, const char *btn, const char *ev);
int proto_format_ble(char *buf, size_t cap, bool connected);
int proto_format_battery_serial(char *buf, size_t cap, int soc, int mv, bool usb,
                                uint32_t heap, int backlight);
int proto_format_battery_ble(char *buf, size_t cap, int soc, int backlight);
int proto_format_log(char *buf, size_t cap, char lvl, const char *msg);
int proto_format_will_change(char *buf, size_t cap, const char *id, const char *kind,
                             const char *theme, const int region[4]);
int proto_format_changed(char *buf, size_t cap, const char *id, const char *theme);
int proto_format_stats(char *buf, size_t cap, const card_stats_t *s);
int proto_format_celebrate(char *buf, size_t cap, int32_t delta, int32_t followers);

// JSON string escaping ("\\", "\"", control characters). Returns bytes written
// (excluding NUL); truncates safely at cap-1.
size_t proto_json_escape(char *dst, size_t cap, const char *src);
