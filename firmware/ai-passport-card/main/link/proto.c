// main/link/proto.c — see proto.h. Parsing uses cJSON; formatting uses snprintf so
// that hot paths (log lines, acks) never allocate.
#include "link/proto.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "cJSON.h"

static const char *const THEMES[CARD_THEME_COUNT] = { "base", "neon-city", "data-nebula" };

// ---------------------------------------------------------------------------
// Themes
// ---------------------------------------------------------------------------
bool proto_theme_known(const char *theme)
{
    if (!theme) return false;
    for (int i = 0; i < CARD_THEME_COUNT; i++) {
        if (strcmp(theme, THEMES[i]) == 0) return true;
    }
    return false;
}

const char *proto_theme_normalize(const char *theme)
{
    return THEMES[proto_theme_index(theme)];
}

int proto_theme_index(const char *theme)
{
    if (!theme) return 0;
    for (int i = 0; i < CARD_THEME_COUNT; i++) {
        if (strcmp(theme, THEMES[i]) == 0) return i;
    }
    return 0;
}

const char *proto_theme_at(int index)
{
    int i = index % CARD_THEME_COUNT;
    if (i < 0) i += CARD_THEME_COUNT;
    return THEMES[i];
}

// ---------------------------------------------------------------------------
// Bottom-strip text
// ---------------------------------------------------------------------------
// One code point of UTF-8. Returns the bytes consumed, or 0 when the sequence is
// malformed (truncated, stray continuation byte, overlong, surrogate, > U+10FFFF).
// Safe on NUL-terminated input: NUL is never a continuation byte, so the scan stops.
static int utf8_next(const char *s, uint32_t *cp)
{
    const unsigned char *p = (const unsigned char *)s;
    unsigned char c = p[0];
    if (c < 0x80) { *cp = c; return 1; }
    int n;
    uint32_t v;
    if      ((c & 0xE0) == 0xC0) { n = 2; v = (uint32_t)(c & 0x1F); }
    else if ((c & 0xF0) == 0xE0) { n = 3; v = (uint32_t)(c & 0x0F); }
    else if ((c & 0xF8) == 0xF0) { n = 4; v = (uint32_t)(c & 0x07); }
    else return 0;
    for (int i = 1; i < n; i++) {
        if ((p[i] & 0xC0) != 0x80) return 0;
        v = (v << 6) | (uint32_t)(p[i] & 0x3F);
    }
    if (v > 0x10FFFF) return 0;
    if (v >= 0xD800 && v <= 0xDFFF) return 0;
    if ((n == 2 && v < 0x80) || (n == 3 && v < 0x800) || (n == 4 && v < 0x10000)) return 0;
    *cp = v;
    return n;
}

// The 19 glyphs in font_digits_36/20 (tools/gen_fonts.sh). No comma, matching
// stats_format_followers() here and CardStats.compact on the Vision Pro.
static bool strip_glyph(uint32_t cp)
{
    if (cp >= '0' && cp <= '9') return true;
    switch (cp) {
    case ' ': case '+': case '-': case '.': case 'k':
    case 0x25B2:   /* ▲ */
    case 0x25BC:   /* ▼ */
    case 0x2665:   /* ♥ */
    case 0x4E07:   /* 万 */
        return true;
    default:
        return false;
    }
}

bool proto_strip_text_valid(const char *text)
{
    if (!text) return false;
    int n = 0;
    for (const char *p = text; *p; ) {
        uint32_t cp;
        int k = utf8_next(p, &cp);
        if (k == 0 || !strip_glyph(cp)) return false;
        if (++n > CARD_STRIP_MAX_CODEPOINTS) return false;
        p += k;
    }
    return n >= 1;
}

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------
static bool get_str(const cJSON *obj, const char *key, char *dst, size_t cap)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (!cJSON_IsString(it) || !it->valuestring) return false;
    size_t n = strlen(it->valuestring);
    if (n >= cap) return false;
    memcpy(dst, it->valuestring, n + 1);
    return true;
}

static bool get_i64(const cJSON *obj, const char *key, int64_t *out)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (!cJSON_IsNumber(it)) return false;
    double d = it->valuedouble;
    if (d > 9.2e18 || d < -9.2e18) return false;
    *out = (int64_t)d;
    return true;
}

static bool get_i32(const cJSON *obj, const char *key, int32_t *out)
{
    int64_t v;
    if (!get_i64(obj, key, &v) || v > INT32_MAX || v < INT32_MIN) return false;
    *out = (int32_t)v;
    return true;
}

// Like get_i32, but also rejects a number with a fractional part: the protocol says
// a `glow` "ms" that is not an integer falls back to the default, and 700.5 must not
// quietly become 700.
static bool get_i32_exact(const cJSON *obj, const char *key, int32_t *out)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (!cJSON_IsNumber(it)) return false;
    double d = it->valuedouble;
    if (d > (double)INT32_MAX || d < (double)INT32_MIN) return false;
    if (d != (double)(int32_t)d) return false;
    *out = (int32_t)d;
    return true;
}

static bool get_bool(const cJSON *obj, const char *key, bool *out)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (!cJSON_IsBool(it)) return false;
    *out = cJSON_IsTrue(it);
    return true;
}

static void parse_stats(const cJSON *root, proto_msg_t *m)
{
    card_stats_t s = { 0 };
    bool ok = get_i32(root, "followers", &s.followers) && get_i64(root, "ts", &s.ts);
    (void)get_i32(root, "likes", &s.likes);
    (void)get_i32(root, "notes", &s.notes);
    (void)get_i32(root, "delta", &s.delta);
    if (s.delta < 0) s.delta = 0;
    if (ok && s.followers >= 0 && s.ts >= 0 && s.likes >= 0 && s.notes >= 0) {
        m->stats = s;
        m->stats_valid = true;
    }
}

bool proto_parse(const char *line, size_t len, proto_msg_t *out)
{
    memset(out, 0, sizeof(*out));
    out->percent = -1;
    if (!line || len == 0 || len > PROTO_LINE_MAX) return false;

    cJSON *root = cJSON_ParseWithLength(line, len);
    if (!root) return false;
    const cJSON *t = cJSON_GetObjectItemCaseSensitive(root, "t");
    if (!cJSON_IsObject(root) || !cJSON_IsString(t) || !t->valuestring) {
        cJSON_Delete(root);
        return false;
    }
    out->has_id = get_str(root, "id", out->id, sizeof(out->id));
    const char *type = t->valuestring;

    if (strcmp(type, "hello") == 0) {
        out->type = PROTO_HELLO;
        (void)get_bool(root, "muteLogs", &out->mute_logs);
    } else if (strcmp(type, "stats") == 0) {
        out->type = PROTO_STATS;
        parse_stats(root, out);
    } else if (strcmp(type, "celebrate") == 0) {
        out->type = PROTO_CELEBRATE;
        (void)get_i32(root, "delta", &out->delta);
        if (out->delta < 0) out->delta = 0;
    } else if (strcmp(type, "set_theme") == 0) {
        out->type = PROTO_SET_THEME;
        char raw[32];
        const cJSON *it = cJSON_GetObjectItemCaseSensitive(root, "theme");
        out->theme_valid = cJSON_IsString(it) && it->valuestring;
        if (out->theme_valid && get_str(root, "theme", raw, sizeof(raw))) {
            strcpy(out->theme, proto_theme_normalize(raw));
        } else {
            strcpy(out->theme, THEMES[0]);   // long/odd ids are "other worlds" -> base
        }
    } else if (strcmp(type, "set_mode") == 0) {
        out->type = PROTO_SET_MODE;
        char mode[8];
        if (get_str(root, "mode", mode, sizeof(mode))) {
            if (strcmp(mode, "idle") == 0) { out->mode = CARD_MODE_IDLE; out->mode_valid = true; }
            if (strcmp(mode, "ar") == 0)   { out->mode = CARD_MODE_AR;   out->mode_valid = true; }
        }
    } else if (strcmp(type, "play_cue") == 0) {
        out->type = PROTO_PLAY_CUE;
        (void)get_str(root, "cue", out->cue, sizeof(out->cue));
    } else if (strcmp(type, "backlight") == 0) {
        out->type = PROTO_BACKLIGHT;
        int32_t p;
        if (get_i32(root, "percent", &p) && p >= 0 && p <= 100) out->percent = (int)p;
    } else if (strcmp(type, "cmd") == 0) {
        out->type = PROTO_CMD;
        const cJSON *c = cJSON_GetObjectItemCaseSensitive(root, "c");
        if (cJSON_IsString(c) && c->valuestring) {
            cJSON_DeleteItemFromObjectCaseSensitive(root, "id");
            char *s = cJSON_PrintUnformatted(root);
            if (s) {
                if (strlen(s) < sizeof(out->cmd)) strcpy(out->cmd, s);
                cJSON_free(s);
            }
        }
    } else if (strcmp(type, "strip") == 0) {
        out->type = PROTO_STRIP;
        // No "text" key at all = restore the follower count. Any other shape that is
        // not a showable string is a glyph error: never silently restore instead.
        const cJSON *it = cJSON_GetObjectItemCaseSensitive(root, "text");
        out->strip_has_text = it != NULL;
        if (out->strip_has_text && get_str(root, "text", out->strip_text, sizeof(out->strip_text)) &&
            proto_strip_text_valid(out->strip_text)) {
            out->strip_valid = true;
        } else {
            out->strip_text[0] = '\0';
        }
    } else if (strcmp(type, "glow") == 0) {
        out->type = PROTO_GLOW;
        // Everything falls back to a usable value: the glow is a decoration, never
        // a reason to refuse a command. "ms" must be a whole JSON number inside
        // [CARD_GLOW_MS_MIN, CARD_GLOW_MS_MAX]; a string, bool, null, a missing key,
        // a fractional number or an out-of-range one all become CARD_GLOW_MS_DEFAULT.
        int32_t ms;
        out->glow_ms = (get_i32_exact(root, "ms", &ms) && ms >= CARD_GLOW_MS_MIN && ms <= CARD_GLOW_MS_MAX)
                           ? (int)ms
                           : CARD_GLOW_MS_DEFAULT;
        char kind[12];
        out->glow_kind = (get_str(root, "kind", kind, sizeof(kind)) && strcmp(kind, "flash") == 0)
                             ? CARD_GLOW_FLASH
                             : CARD_GLOW_SWEEP;   // "sweep", unknown or missing
    } else if (strcmp(type, "sleep") == 0) {
        out->type = PROTO_SLEEP;
    } else if (strcmp(type, "ping") == 0) {
        out->type = PROTO_PING;
    } else if (strcmp(type, "ack") == 0) {
        out->type = PROTO_ACK;
        (void)get_bool(root, "ok", &out->ack_ok);
    } else {
        out->type = PROTO_UNKNOWN;
    }
    cJSON_Delete(root);
    return true;
}

bool proto_is_ack_for(const char *line, size_t len, const char *id)
{
    if (!line || !id || !*id || len == 0 || len > PROTO_LINE_MAX) return false;
    // Cheap pre-filter before parsing: every ack contains the token "ack".
    bool seen = false;
    for (size_t i = 0; i + 5 <= len && !seen; i++) seen = memcmp(line + i, "\"ack\"", 5) == 0;
    if (!seen) return false;
    cJSON *root = cJSON_ParseWithLength(line, len);
    if (!root) return false;
    const cJSON *t = cJSON_GetObjectItemCaseSensitive(root, "t");
    const cJSON *i = cJSON_GetObjectItemCaseSensitive(root, "id");
    bool match = cJSON_IsString(t) && t->valuestring && strcmp(t->valuestring, "ack") == 0 &&
                 cJSON_IsString(i) && i->valuestring && strcmp(i->valuestring, id) == 0;
    cJSON_Delete(root);
    return match;
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------
size_t proto_json_escape(char *dst, size_t cap, const char *src)
{
    static const char HEX[] = "0123456789abcdef";
    size_t n = 0;
    if (cap == 0) return 0;
    for (const unsigned char *p = (const unsigned char *)src; src && *p; p++) {
        char tmp[8];
        size_t k;
        unsigned char c = *p;
        if (c == '"' || c == '\\') { tmp[0] = '\\'; tmp[1] = (char)c; k = 2; }
        else if (c == '\n') { tmp[0] = '\\'; tmp[1] = 'n'; k = 2; }
        else if (c == '\r') { tmp[0] = '\\'; tmp[1] = 'r'; k = 2; }
        else if (c == '\t') { tmp[0] = '\\'; tmp[1] = 't'; k = 2; }
        else if (c < 0x20) {
            tmp[0] = '\\'; tmp[1] = 'u'; tmp[2] = '0'; tmp[3] = '0';
            tmp[4] = HEX[c >> 4]; tmp[5] = HEX[c & 0xF]; k = 6;
        } else { tmp[0] = (char)c; k = 1; }
        if (n + k >= cap) break;
        memcpy(dst + n, tmp, k);
        n += k;
    }
    dst[n] = '\0';
    return n;
}

// Append helper: pos saturates at cap so a truncated line is detected once at the end.
static void ap(char *buf, size_t cap, size_t *pos, const char *fmt, ...)
{
    if (*pos >= cap) return;
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(buf + *pos, cap - *pos, fmt, args);
    va_end(args);
    if (n < 0) { *pos = cap; return; }
    *pos += (size_t)n;
    if (*pos > cap) *pos = cap;
}

static int finish(char *buf, size_t cap, size_t pos)
{
    if (cap == 0) return -1;
    if (pos >= cap) { buf[cap - 1] = '\0'; return -1; }
    return (int)pos;
}

static void ap_stats(char *buf, size_t cap, size_t *pos, const card_stats_t *s)
{
    ap(buf, cap, pos, "{\"followers\":%ld,\"likes\":%ld,\"notes\":%ld,\"delta\":%ld,\"ts\":%lld}",
       (long)s->followers, (long)s->likes, (long)s->notes, (long)s->delta, (long long)s->ts);
}

static bool numeric_token(const char *s)
{
    if (!s || !*s) return false;
    for (; *s; s++) {
        if (!((*s >= '0' && *s <= '9') || *s == '.')) return false;
    }
    return true;
}

int proto_format_hello(char *buf, size_t cap, const proto_hello_t *h)
{
    size_t pos = 0;
    ap(buf, cap, &pos, "{\"t\":\"hello\",\"fw\":\"%s\",\"boot\":%lu,\"mode\":\"%s\",\"theme\":\"%s\",\"stats\":",
       h->fw ? h->fw : CARD_FW_VERSION, (unsigned long)h->boot,
       h->mode == CARD_MODE_AR ? "ar" : "idle", proto_theme_normalize(h->theme));
    ap_stats(buf, cap, &pos, &h->stats);
    ap(buf, cap, &pos, ",\"battery\":{\"soc\":%d,\"mv\":%d},\"ble\":{\"connected\":%s},\"heap\":%lu,\"backlight\":%d",
       h->soc, h->mv, h->ble_connected ? "true" : "false", (unsigned long)h->heap, h->backlight);
    if (numeric_token(h->screen_width_mm)) {
        ap(buf, cap, &pos, ",\"screenWidthMm\":%s", h->screen_width_mm);
    }
    ap(buf, cap, &pos, "}");
    return finish(buf, cap, pos);
}

int proto_format_ack(char *buf, size_t cap, const char *id, bool ok, const char *err,
                     const char *theme)
{
    char eid[PROTO_ID_MAX * 6];
    proto_json_escape(eid, sizeof(eid), id ? id : "");
    size_t pos = 0;
    ap(buf, cap, &pos, "{\"t\":\"ack\",\"id\":\"%s\",\"ok\":%s", eid, ok ? "true" : "false");
    if (err && *err) {
        char eerr[64];
        proto_json_escape(eerr, sizeof(eerr), err);
        ap(buf, cap, &pos, ",\"err\":\"%s\"", eerr);
    }
    if (theme && *theme) ap(buf, cap, &pos, ",\"theme\":\"%s\"", proto_theme_normalize(theme));
    ap(buf, cap, &pos, "}");
    return finish(buf, cap, pos);
}

int proto_format_button(char *buf, size_t cap, const char *btn, const char *ev)
{
    size_t pos = 0;
    ap(buf, cap, &pos, "{\"t\":\"button\",\"btn\":\"%s\",\"ev\":\"%s\"}", btn, ev);
    return finish(buf, cap, pos);
}

int proto_format_ble(char *buf, size_t cap, bool connected)
{
    size_t pos = 0;
    ap(buf, cap, &pos, "{\"t\":\"ble\",\"connected\":%s}", connected ? "true" : "false");
    return finish(buf, cap, pos);
}

int proto_format_battery_serial(char *buf, size_t cap, int soc, int mv, bool usb, uint32_t heap,
                                int backlight)
{
    size_t pos = 0;
    ap(buf, cap, &pos,
       "{\"t\":\"battery\",\"soc\":%d,\"mv\":%d,\"usb\":%s,\"heap\":%lu,\"backlight\":%d}",
       soc, mv, usb ? "true" : "false", (unsigned long)heap, backlight);
    return finish(buf, cap, pos);
}

int proto_format_battery_ble(char *buf, size_t cap, int soc, int backlight)
{
    size_t pos = 0;
    ap(buf, cap, &pos, "{\"t\":\"battery\",\"soc\":%d,\"backlight\":%d}", soc, backlight);
    return finish(buf, cap, pos);
}

int proto_format_log(char *buf, size_t cap, char lvl, const char *msg)
{
    size_t pos = 0;
    ap(buf, cap, &pos, "{\"t\":\"log\",\"lvl\":\"%c\",\"msg\":\"", lvl);
    if (pos < cap) pos += proto_json_escape(buf + pos, cap - pos, msg ? msg : "");
    ap(buf, cap, &pos, "\"}");
    return finish(buf, cap, pos);
}

int proto_format_will_change(char *buf, size_t cap, const char *id, const char *kind,
                             const char *theme, const int region[4])
{
    size_t pos = 0;
    ap(buf, cap, &pos, "{\"t\":\"will_change\",\"id\":\"%s\",\"kind\":\"%s\",\"theme\":\"%s\",\"region\":[%d,%d,%d,%d]}",
       id, kind, proto_theme_normalize(theme), region[0], region[1], region[2], region[3]);
    return finish(buf, cap, pos);
}

int proto_format_changed(char *buf, size_t cap, const char *id, const char *theme)
{
    size_t pos = 0;
    ap(buf, cap, &pos, "{\"t\":\"changed\",\"id\":\"%s\",\"theme\":\"%s\"}", id,
       proto_theme_normalize(theme));
    return finish(buf, cap, pos);
}

int proto_format_stats(char *buf, size_t cap, const card_stats_t *s)
{
    size_t pos = 0;
    ap(buf, cap, &pos, "{\"t\":\"stats\",\"followers\":%ld,\"likes\":%ld,\"notes\":%ld,\"delta\":%ld,\"ts\":%lld}",
       (long)s->followers, (long)s->likes, (long)s->notes, (long)s->delta, (long long)s->ts);
    return finish(buf, cap, pos);
}

int proto_format_celebrate(char *buf, size_t cap, int32_t delta, int32_t followers)
{
    size_t pos = 0;
    ap(buf, cap, &pos, "{\"t\":\"celebrate\",\"delta\":%ld,\"followers\":%ld}", (long)delta,
       (long)followers);
    return finish(buf, cap, pos);
}
