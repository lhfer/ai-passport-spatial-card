// Host test: protocol parsing, theme mapping, ack matching and line formatting.
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "link/proto.h"

#define PARSE(s, m) proto_parse((s), strlen(s), (m))

static void test_invalid(void)
{
    proto_msg_t m;
    assert(!PARSE("", &m));
    assert(!PARSE("not json", &m));
    assert(!PARSE("[1,2]", &m));
    assert(!PARSE("{\"x\":1}", &m));               // no "t"
    assert(!PARSE("{\"t\":5}", &m));               // "t" not a string
    char big[PROTO_LINE_MAX + 10];
    memset(big, ' ', sizeof(big));
    memcpy(big, "{\"t\":\"ping\"", 11);
    big[sizeof(big) - 1] = '\0';
    assert(!proto_parse(big, strlen(big), &m));    // over 512 bytes
}

static void test_types(void)
{
    proto_msg_t m;
    assert(PARSE("{\"t\":\"hello\",\"id\":\"h1\",\"hub\":\"spatial-hub/0.1\",\"muteLogs\":true}", &m));
    assert(m.type == PROTO_HELLO && m.has_id && strcmp(m.id, "h1") == 0 && m.mute_logs);
    assert(PARSE("{\"t\":\"hello\"}", &m));
    assert(m.type == PROTO_HELLO && !m.has_id && !m.mute_logs);

    assert(PARSE("{\"t\":\"stats\",\"id\":\"s1\",\"followers\":4318,\"likes\":44012,\"notes\":128,\"delta\":5,\"ts\":1758153600}", &m));
    assert(m.type == PROTO_STATS && m.stats_valid);
    assert(m.stats.followers == 4318 && m.stats.likes == 44012 && m.stats.notes == 128);
    assert(m.stats.delta == 5 && m.stats.ts == 1758153600LL);
    assert(PARSE("{\"t\":\"stats\",\"followers\":1}", &m));          // ts missing
    assert(m.type == PROTO_STATS && !m.stats_valid);
    assert(PARSE("{\"t\":\"stats\",\"followers\":-1,\"ts\":5}", &m)); // negative
    assert(!m.stats_valid);
    assert(PARSE("{\"t\":\"stats\",\"followers\":7,\"ts\":5,\"delta\":-3}", &m));
    assert(m.stats_valid && m.stats.delta == 0 && m.stats.likes == 0);

    assert(PARSE("{\"t\":\"celebrate\",\"id\":\"c1\",\"delta\":5}", &m));
    assert(m.type == PROTO_CELEBRATE && m.delta == 5);
    assert(PARSE("{\"t\":\"celebrate\"}", &m) && m.delta == 0);

    assert(PARSE("{\"t\":\"set_theme\",\"id\":\"v9\",\"theme\":\"neon-city\"}", &m));
    assert(m.type == PROTO_SET_THEME && m.theme_valid && strcmp(m.theme, "neon-city") == 0);
    assert(PARSE("{\"t\":\"set_theme\",\"theme\":\"code-sea\"}", &m));
    assert(m.theme_valid && strcmp(m.theme, "base") == 0);            // other worlds -> base
    assert(PARSE("{\"t\":\"set_theme\",\"theme\":\"a-very-long-world-identifier-that-overflows\"}", &m));
    assert(m.theme_valid && strcmp(m.theme, "base") == 0);
    assert(PARSE("{\"t\":\"set_theme\"}", &m) && !m.theme_valid);

    assert(PARSE("{\"t\":\"set_mode\",\"mode\":\"ar\"}", &m));
    assert(m.type == PROTO_SET_MODE && m.mode_valid && m.mode == CARD_MODE_AR);
    assert(PARSE("{\"t\":\"set_mode\",\"mode\":\"idle\"}", &m) && m.mode == CARD_MODE_IDLE);
    assert(PARSE("{\"t\":\"set_mode\",\"mode\":\"weird\"}", &m) && !m.mode_valid);

    assert(PARSE("{\"t\":\"play_cue\",\"cue\":\"tick\"}", &m));
    assert(m.type == PROTO_PLAY_CUE && strcmp(m.cue, "tick") == 0);

    assert(PARSE("{\"t\":\"backlight\",\"percent\":30}", &m));
    assert(m.type == PROTO_BACKLIGHT && m.percent == 30);
    assert(PARSE("{\"t\":\"backlight\",\"percent\":130}", &m) && m.percent == -1);
    assert(PARSE("{\"t\":\"backlight\"}", &m) && m.percent == -1);

    assert(PARSE("{\"t\":\"cmd\",\"id\":\"d1\",\"c\":\"theme\",\"arg\":{\"w\":\"neon-city\"}}", &m));
    assert(m.type == PROTO_CMD && strcmp(m.id, "d1") == 0);
    assert(strcmp(m.cmd, "{\"t\":\"cmd\",\"c\":\"theme\",\"arg\":{\"w\":\"neon-city\"}}") == 0);
    assert(PARSE("{\"t\":\"cmd\",\"id\":\"d2\"}", &m) && m.cmd[0] == '\0');   // no "c"

    assert(PARSE("{\"t\":\"sleep\",\"id\":\"z\"}", &m) && m.type == PROTO_SLEEP);
    assert(PARSE("{\"t\":\"ping\",\"id\":\"p\"}", &m) && m.type == PROTO_PING);
    assert(PARSE("{\"t\":\"ack\",\"id\":\"w3\",\"ok\":true}", &m));
    assert(m.type == PROTO_ACK && m.ack_ok && strcmp(m.id, "w3") == 0);
    assert(PARSE("{\"t\":\"teleport\",\"id\":\"u\"}", &m) && m.type == PROTO_UNKNOWN);
    assert(m.has_id && strcmp(m.id, "u") == 0);
    // ids longer than PROTO_ID_MAX-1 are treated as absent (never truncated)
    assert(PARSE("{\"t\":\"ping\",\"id\":\"0123456789012345678901234567\"}", &m) && !m.has_id);
}

// `strip` (docs/protocol.md "底条覆盖"): 1-12 code points from "0123456789.+-k万▲▼♥ ".
#define HEART "\xE2\x99\xA5"   /* U+2665 */
#define WAN   "\xE4\xB8\x87"   /* U+4E07 */

static void test_strip_text_valid(void)
{
    assert(proto_strip_text_valid(HEART "1825"));
    assert(proto_strip_text_valid("4313"));
    assert(proto_strip_text_valid("1.2" WAN));
    assert(proto_strip_text_valid("\xE2\x96\xB2" "+12"));       /* ▲+12 */
    assert(proto_strip_text_valid("\xE2\x96\xBC" "-3"));        /* ▼-3 */
    assert(proto_strip_text_valid("44k"));
    assert(proto_strip_text_valid(HEART " 1 8"));               /* space is in the set */
    assert(proto_strip_text_valid("123456789012"));             /* 12 code points */
    assert(proto_strip_text_valid(HEART HEART HEART HEART HEART HEART
                                  HEART HEART HEART HEART HEART HEART));  /* 12 cp, 36 bytes */

    assert(!proto_strip_text_valid(NULL));
    assert(!proto_strip_text_valid(""));                        /* 0 code points */
    assert(!proto_strip_text_valid("1234567890123"));           /* 13 code points */
    assert(!proto_strip_text_valid(HEART HEART HEART HEART HEART HEART HEART
                                   HEART HEART HEART HEART HEART HEART)); /* 13 cp, 39 bytes */
    assert(!proto_strip_text_valid("1,825"));                   /* no comma in the font */
    assert(!proto_strip_text_valid("abc"));
    assert(!proto_strip_text_valid("K"));                       /* lowercase k only */
    assert(!proto_strip_text_valid(HEART "\n"));
    // malformed UTF-8 never reaches the label
    assert(!proto_strip_text_valid("\xE2\x99"));                /* truncated 3-byte ♥ */
    assert(!proto_strip_text_valid("\x99\xA5"));                /* stray continuation bytes */
    assert(!proto_strip_text_valid("\xC0\xAE"));                /* overlong '.' */
    assert(!proto_strip_text_valid("\xED\xA0\x80"));            /* surrogate U+D800 */
    assert(!proto_strip_text_valid("\xF4\x90\x80\x80"));        /* > U+10FFFF */
}

static void test_strip(void)
{
    proto_msg_t m;
    assert(PARSE("{\"t\":\"strip\",\"id\":\"n7\",\"text\":\"" HEART "1825\"}", &m));
    assert(m.type == PROTO_STRIP && m.has_id && strcmp(m.id, "n7") == 0);
    assert(m.strip_has_text && m.strip_valid && strcmp(m.strip_text, HEART "1825") == 0);
    // the \uXXXX escape decodes to the same UTF-8
    assert(PARSE("{\"t\":\"strip\",\"id\":\"n7\",\"text\":\"\\u26651825\"}", &m));
    assert(m.strip_valid && strcmp(m.strip_text, HEART "1825") == 0);

    assert(PARSE("{\"t\":\"strip\",\"id\":\"n8\"}", &m));        // no text = restore followers
    assert(m.type == PROTO_STRIP && !m.strip_has_text && !m.strip_valid && m.strip_text[0] == '\0');

    // has_text && !valid -> ack ok:false err:"glyph"; the strip is left alone
    assert(PARSE("{\"t\":\"strip\",\"id\":\"n9\",\"text\":\"1,825\"}", &m));
    assert(m.strip_has_text && !m.strip_valid && m.strip_text[0] == '\0');
    assert(PARSE("{\"t\":\"strip\",\"text\":\"1234567890123\"}", &m));     // 13 code points
    assert(m.strip_has_text && !m.strip_valid);
    assert(PARSE("{\"t\":\"strip\",\"text\":\"\"}", &m) && m.strip_has_text && !m.strip_valid);
    assert(PARSE("{\"t\":\"strip\",\"text\":5}", &m) && m.strip_has_text && !m.strip_valid);
    assert(PARSE("{\"t\":\"strip\",\"text\":null}", &m) && m.strip_has_text && !m.strip_valid);
    // longer than the buffer (14 x 万 = 42 bytes): rejected, never truncated
    assert(PARSE("{\"t\":\"strip\",\"text\":\"" WAN WAN WAN WAN WAN WAN WAN
                 WAN WAN WAN WAN WAN WAN WAN "\"}", &m));
    assert(m.strip_has_text && !m.strip_valid && m.strip_text[0] == '\0');

    char buf[PROTO_LINE_MAX + 1];
    assert(proto_format_ack(buf, sizeof(buf), "n9", false, "glyph", NULL) > 0);
    assert(strcmp(buf, "{\"t\":\"ack\",\"id\":\"n9\",\"ok\":false,\"err\":\"glyph\"}") == 0);
}

// `glow` (docs/protocol.md 「屏幕闪光 glow」): every field falls back to a usable
// value, so a glow is never refused for its arguments.
static void test_glow(void)
{
    proto_msg_t m;
    // defaults: no ms, no kind, no id
    assert(PARSE("{\"t\":\"glow\"}", &m));
    assert(m.type == PROTO_GLOW && !m.has_id);
    assert(m.glow_ms == CARD_GLOW_MS_DEFAULT && m.glow_ms == 300);
    assert(m.glow_kind == CARD_GLOW_SWEEP);

    // id is optional but carried through when present
    assert(PARSE("{\"t\":\"glow\",\"id\":\"g1\",\"ms\":300,\"kind\":\"sweep\"}", &m));
    assert(m.type == PROTO_GLOW && m.has_id && strcmp(m.id, "g1") == 0);
    assert(m.glow_ms == 300 && m.glow_kind == CARD_GLOW_SWEEP);

    // ms range: 50..1000 inclusive, anything else -> 300
    assert(PARSE("{\"t\":\"glow\",\"ms\":50}", &m) && m.glow_ms == 50);
    assert(PARSE("{\"t\":\"glow\",\"ms\":1000}", &m) && m.glow_ms == 1000);
    assert(PARSE("{\"t\":\"glow\",\"ms\":49}", &m) && m.glow_ms == 300);
    assert(PARSE("{\"t\":\"glow\",\"ms\":1001}", &m) && m.glow_ms == 300);
    assert(PARSE("{\"t\":\"glow\",\"ms\":0}", &m) && m.glow_ms == 300);
    assert(PARSE("{\"t\":\"glow\",\"ms\":-300}", &m) && m.glow_ms == 300);
    assert(PARSE("{\"t\":\"glow\",\"ms\":99999999999}", &m) && m.glow_ms == 300);
    // an integral JSON number is fine however it is spelled
    assert(PARSE("{\"t\":\"glow\",\"ms\":600.0}", &m) && m.glow_ms == 600);
    // not an integer -> 300, never truncated to something in range
    assert(PARSE("{\"t\":\"glow\",\"ms\":700.5}", &m) && m.glow_ms == 300);
    assert(PARSE("{\"t\":\"glow\",\"ms\":49.9}", &m) && m.glow_ms == 300);
    assert(PARSE("{\"t\":\"glow\",\"ms\":300.5}", &m) && m.glow_ms == 300);
    // not an integer (string / bool / null / object) -> 300
    assert(PARSE("{\"t\":\"glow\",\"ms\":\"300\"}", &m) && m.glow_ms == 300);
    assert(PARSE("{\"t\":\"glow\",\"ms\":true}", &m) && m.glow_ms == 300);
    assert(PARSE("{\"t\":\"glow\",\"ms\":null}", &m) && m.glow_ms == 300);
    assert(PARSE("{\"t\":\"glow\",\"ms\":{}}", &m) && m.glow_ms == 300);
    // ... and a valid ms survives an unknown kind
    assert(PARSE("{\"t\":\"glow\",\"ms\":600,\"kind\":\"strobe\"}", &m));
    assert(m.glow_ms == 600 && m.glow_kind == CARD_GLOW_SWEEP);

    // kind: "flash" or (anything else) sweep
    assert(PARSE("{\"t\":\"glow\",\"kind\":\"flash\"}", &m) && m.glow_kind == CARD_GLOW_FLASH);
    assert(PARSE("{\"t\":\"glow\",\"kind\":\"sweep\"}", &m) && m.glow_kind == CARD_GLOW_SWEEP);
    assert(PARSE("{\"t\":\"glow\",\"kind\":\"Flash\"}", &m) && m.glow_kind == CARD_GLOW_SWEEP);
    assert(PARSE("{\"t\":\"glow\",\"kind\":5}", &m) && m.glow_kind == CARD_GLOW_SWEEP);
    assert(PARSE("{\"t\":\"glow\",\"kind\":null}", &m) && m.glow_kind == CARD_GLOW_SWEEP);
    // a kind longer than the parse buffer is still just an unknown kind
    assert(PARSE("{\"t\":\"glow\",\"kind\":\"flashflashflashflash\"}", &m));
    assert(m.glow_kind == CARD_GLOW_SWEEP);

    // the ack the device sends back immediately, and the refusal an old firmware
    // (no PROTO_GLOW) answers with instead
    char buf[PROTO_LINE_MAX + 1];
    assert(proto_format_ack(buf, sizeof(buf), "g1", true, NULL, NULL) > 0);
    assert(strcmp(buf, "{\"t\":\"ack\",\"id\":\"g1\",\"ok\":true}") == 0);
    assert(proto_format_ack(buf, sizeof(buf), "g1", false, "unknown", NULL) > 0);
    assert(strcmp(buf, "{\"t\":\"ack\",\"id\":\"g1\",\"ok\":false,\"err\":\"unknown\"}") == 0);

    // the `fw` gate that tells a glow-capable device from an old one
    assert(strcmp(CARD_FW_VERSION, "0.2.1") == 0);
}

// Screen lock (CONFIG_CARD_SCREEN_LOCK, app_state.c): the parser is unchanged --
// a `set_theme` still decodes normally -- and the refusal is the app layer answering
// with err "locked" and no "theme" field, because nothing on the screen changed.
static void test_screen_lock_refusal(void)
{
    proto_msg_t m;
    assert(PARSE("{\"t\":\"set_theme\",\"id\":\"v9\",\"theme\":\"neon-city\"}", &m));
    assert(m.type == PROTO_SET_THEME && m.has_id && m.theme_valid);
    assert(strcmp(m.theme, "neon-city") == 0);

    char buf[PROTO_LINE_MAX + 1];
    assert(proto_format_ack(buf, sizeof(buf), m.id, false, "locked", NULL) > 0);
    assert(strcmp(buf, "{\"t\":\"ack\",\"id\":\"v9\",\"ok\":false,\"err\":\"locked\"}") == 0);
    // the Hub/VP must be able to read its own refusal back
    proto_msg_t a;
    assert(proto_parse(buf, strlen(buf), &a));
    assert(a.type == PROTO_ACK && !a.ack_ok && strcmp(a.id, "v9") == 0);
}

static void test_ack_match(void)
{
    const char *ack = "{\"t\":\"ack\",\"id\":\"w3\",\"ok\":true}";
    assert(proto_is_ack_for(ack, strlen(ack), "w3"));
    assert(!proto_is_ack_for(ack, strlen(ack), "w4"));
    const char *other = "{\"t\":\"set_theme\",\"id\":\"w3\",\"theme\":\"base\"}";
    assert(!proto_is_ack_for(other, strlen(other), "w3"));
    assert(!proto_is_ack_for("garbage", 7, "w3"));
    assert(!proto_is_ack_for(ack, strlen(ack), ""));
}

static void test_themes(void)
{
    assert(strcmp(proto_theme_normalize("base"), "base") == 0);
    assert(strcmp(proto_theme_normalize("neon-city"), "neon-city") == 0);
    assert(strcmp(proto_theme_normalize("data-nebula"), "data-nebula") == 0);
    assert(strcmp(proto_theme_normalize("deep-sea"), "base") == 0);
    assert(strcmp(proto_theme_normalize("paper-valley"), "base") == 0);
    assert(strcmp(proto_theme_normalize(NULL), "base") == 0);
    assert(proto_theme_known("neon-city") && !proto_theme_known("code-sea") && !proto_theme_known(NULL));
    assert(proto_theme_index("data-nebula") == 2 && proto_theme_index("nope") == 0);
    assert(strcmp(proto_theme_at(3), "base") == 0);
    assert(strcmp(proto_theme_at(-1), "data-nebula") == 0);
    assert(strcmp(proto_theme_at(4), "neon-city") == 0);
}

static void test_format(void)
{
    char buf[PROTO_LINE_MAX + 1];
    proto_hello_t h = {
        .fw = CARD_FW_VERSION, .boot = 7, .mode = CARD_MODE_IDLE, .theme = "base",
        .stats = { 4313, 44000, 128, 0, 1758150000LL },
        .soc = 88, .mv = 4060, .ble_connected = false, .heap = 181240, .backlight = 100,
        .screen_width_mm = "36.72",
    };
    int n = proto_format_hello(buf, sizeof(buf), &h);
    assert(n > 0 && n == (int)strlen(buf));
    assert(strcmp(buf, "{\"t\":\"hello\",\"fw\":\"0.2.1\",\"boot\":7,\"mode\":\"idle\",\"theme\":\"base\","
                       "\"stats\":{\"followers\":4313,\"likes\":44000,\"notes\":128,\"delta\":0,\"ts\":1758150000},"
                       "\"battery\":{\"soc\":88,\"mv\":4060},\"ble\":{\"connected\":false},\"heap\":181240,"
                       "\"backlight\":100,\"screenWidthMm\":36.72}") == 0);
    h.screen_width_mm = "abc";   // non-numeric Kconfig value is omitted
    h.mode = CARD_MODE_AR; h.theme = "code-sea"; h.soc = -1; h.mv = -1; h.ble_connected = true;
    h.backlight = 60;            // AR level from CONFIG_CARD_AR_BACKLIGHT_PERCENT / `backlight`
    assert(proto_format_hello(buf, sizeof(buf), &h) > 0);
    assert(strstr(buf, "\"mode\":\"ar\",\"theme\":\"base\"") && strstr(buf, "\"soc\":-1,\"mv\":-1")
           && strstr(buf, "\"connected\":true") && strstr(buf, "\"backlight\":60")
           && !strstr(buf, "screenWidthMm"));
    // the hello must be parseable by our own parser (round trip)
    proto_msg_t m;
    assert(proto_parse(buf, strlen(buf), &m) && m.type == PROTO_HELLO);

    assert(proto_format_ack(buf, sizeof(buf), "h1", true, NULL, NULL) > 0);
    assert(strcmp(buf, "{\"t\":\"ack\",\"id\":\"h1\",\"ok\":true}") == 0);
    assert(proto_format_ack(buf, sizeof(buf), "u", false, "unknown", NULL) > 0);
    assert(strcmp(buf, "{\"t\":\"ack\",\"id\":\"u\",\"ok\":false,\"err\":\"unknown\"}") == 0);
    assert(proto_format_ack(buf, sizeof(buf), "v9", true, NULL, "code-sea") > 0);
    assert(strcmp(buf, "{\"t\":\"ack\",\"id\":\"v9\",\"ok\":true,\"theme\":\"base\"}") == 0);
    assert(proto_format_ack(buf, sizeof(buf), "q\"x", true, NULL, NULL) > 0);
    assert(strcmp(buf, "{\"t\":\"ack\",\"id\":\"q\\\"x\",\"ok\":true}") == 0);
    assert(proto_format_ack(buf, sizeof(buf), NULL, true, NULL, NULL) > 0);
    assert(strcmp(buf, "{\"t\":\"ack\",\"id\":\"\",\"ok\":true}") == 0);

    assert(proto_format_button(buf, sizeof(buf), "ok", "long") > 0);
    assert(strcmp(buf, "{\"t\":\"button\",\"btn\":\"ok\",\"ev\":\"long\"}") == 0);
    assert(proto_format_ble(buf, sizeof(buf), true) > 0);
    assert(strcmp(buf, "{\"t\":\"ble\",\"connected\":true}") == 0);
    assert(proto_format_battery_serial(buf, sizeof(buf), 88, 4060, true, 150000, 60) > 0);
    assert(strcmp(buf, "{\"t\":\"battery\",\"soc\":88,\"mv\":4060,\"usb\":true,\"heap\":150000,"
                       "\"backlight\":60}") == 0);
    assert(proto_format_battery_ble(buf, sizeof(buf), -1, 100) > 0);
    assert(strcmp(buf, "{\"t\":\"battery\",\"soc\":-1,\"backlight\":100}") == 0);
    assert(proto_format_log(buf, sizeof(buf), 'W', "bsp: \"quoted\" \\ tab\tnl\n\x01") > 0);
    assert(strcmp(buf, "{\"t\":\"log\",\"lvl\":\"W\",\"msg\":\"bsp: \\\"quoted\\\" \\\\ tab\\tnl\\n\\u0001\"}") == 0);
    const int full[4] = { 0, 0, 240, 320 };
    assert(proto_format_will_change(buf, sizeof(buf), "w3", "theme", "neon-city", full) > 0);
    assert(strcmp(buf, "{\"t\":\"will_change\",\"id\":\"w3\",\"kind\":\"theme\",\"theme\":\"neon-city\",\"region\":[0,0,240,320]}") == 0);
    const int strip[4] = { 0, 272, 240, 48 };
    assert(proto_format_will_change(buf, sizeof(buf), "w4", "stat", "base", strip) > 0);
    assert(strstr(buf, "\"region\":[0,272,240,48]"));
    assert(proto_format_changed(buf, sizeof(buf), "w3", "neon-city") > 0);
    assert(strcmp(buf, "{\"t\":\"changed\",\"id\":\"w3\",\"theme\":\"neon-city\"}") == 0);
    card_stats_t s = { 4318, 44012, 128, 5, 1758153600LL };
    assert(proto_format_stats(buf, sizeof(buf), &s) > 0);
    assert(strcmp(buf, "{\"t\":\"stats\",\"followers\":4318,\"likes\":44012,\"notes\":128,\"delta\":5,\"ts\":1758153600}") == 0);
    assert(proto_format_celebrate(buf, sizeof(buf), 5, 4318) > 0);
    assert(strcmp(buf, "{\"t\":\"celebrate\",\"delta\":5,\"followers\":4318}") == 0);

    // truncation is reported, never silently sent
    char tiny[16];
    assert(proto_format_ack(tiny, sizeof(tiny), "h1", true, NULL, NULL) == -1);
    assert(strlen(tiny) < sizeof(tiny));
    char msg[600];
    memset(msg, 'x', sizeof(msg) - 1);
    msg[sizeof(msg) - 1] = '\0';
    assert(proto_format_log(buf, sizeof(buf), 'I', msg) == -1);

    char esc[8];
    assert(proto_json_escape(esc, sizeof(esc), "ab\"cdef") == 7);   // stops before overflow
    assert(strcmp(esc, "ab\\\"cde") == 0);
}

int main(void)
{
    test_invalid();
    test_types();
    test_strip_text_valid();
    test_strip();
    test_glow();
    test_ack_match();
    test_screen_lock_refusal();
    test_themes();
    test_format();
    puts("proto tests: PASS");
    return 0;
}
