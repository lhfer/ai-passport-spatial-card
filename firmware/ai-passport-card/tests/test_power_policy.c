// Host test: backlight policy decisions.
#include <assert.h>
#include <stdio.h>

#include "power/power_policy.h"

int main(void)
{
    power_inputs_t in = { .ar = false, .usb = false, .idle_ms = 0,
                          .override_percent = -1, .ar_percent = -1 };
    power_decision_t d = power_policy_decide(&in);
    assert(!d.dc && d.percent == 60);

    // --- battery idle ladder (unchanged by the AR level work) ---
    in.idle_ms = POWER_DIM_AFTER_MS - 1;
    assert(power_policy_decide(&in).percent == 60);
    in.idle_ms = POWER_DIM_AFTER_MS;
    assert(power_policy_decide(&in).percent == 30);
    in.idle_ms = POWER_OFF_AFTER_MS - 1;
    assert(power_policy_decide(&in).percent == 30);
    in.idle_ms = POWER_OFF_AFTER_MS;
    assert(power_policy_decide(&in).percent == 0);
    // the same ladder is unaffected by an AR level that is not in use
    in.ar_percent = 60;
    assert(!power_policy_decide(&in).dc && power_policy_decide(&in).percent == 0);
    in.idle_ms = 0;
    assert(!power_policy_decide(&in).dc && power_policy_decide(&in).percent == 60);
    in.ar_percent = -1;

    // --- USB without AR: steady DC, whatever the idle time or the override ---
    in.usb = true;
    in.idle_ms = POWER_OFF_AFTER_MS;
    in.override_percent = 10;
    d = power_policy_decide(&in);
    assert(d.dc && d.percent == 100);
    in.usb = false; in.idle_ms = 0; in.override_percent = -1;

    // --- AR: the AR level wins over USB presence; only 100 is DC ---
    in.ar = true; in.ar_percent = -1;          // unset -> Kconfig-less fallback 100
    d = power_policy_decide(&in);
    assert(d.dc && d.percent == 100);
    in.override_percent = 10;                  // v1 case: AR at 100 still ignores the battery override
    d = power_policy_decide(&in);
    assert(d.dc && d.percent == 100);
    in.override_percent = -1;
    in.ar_percent = 100;                       // explicit 100 is still DC
    d = power_policy_decide(&in);
    assert(d.dc && d.percent == 100);
    in.ar_percent = 60;                        // on battery: real 5 kHz PWM duty
    d = power_policy_decide(&in);
    assert(!d.dc && d.percent == 60);
    in.usb = true;                             // and USB does not push it back to DC 100
    d = power_policy_decide(&in);
    assert(!d.dc && d.percent == 60);
    in.usb = false;
    in.ar_percent = 101;                       // out of range -> fallback 100 (DC)
    d = power_policy_decide(&in);
    assert(d.dc && d.percent == 100);
    in.ar_percent = 0;                         // 0 is a valid (if useless) AR level
    d = power_policy_decide(&in);
    assert(!d.dc && d.percent == 0);

    // A button press clears the Hub override and resets idle_ms, but the glue never
    // touches the AR level (power_policy_note_activity only writes s_override /
    // s_last_activity_ms): neither input can pull the AR session off 60 %.
    in.ar_percent = 60;
    in.override_percent = 15; in.idle_ms = POWER_OFF_AFTER_MS;
    d = power_policy_decide(&in);
    assert(!d.dc && d.percent == 60);
    in.override_percent = -1; in.idle_ms = 0;  // state right after note_activity()
    d = power_policy_decide(&in);
    assert(!d.dc && d.percent == 60);
    in.ar = false;                             // leaving AR falls back to the ladder
    d = power_policy_decide(&in);
    assert(!d.dc && d.percent == 60);
    in.idle_ms = POWER_DIM_AFTER_MS;
    assert(power_policy_decide(&in).percent == 30);
    in.idle_ms = 0;

    // --- Hub override on battery ---
    in.ar = false; in.ar_percent = -1; in.override_percent = 15;
    d = power_policy_decide(&in);
    assert(!d.dc && d.percent == 15);
    in.override_percent = 0;
    assert(power_policy_decide(&in).percent == 0);
    in.override_percent = 101;   // invalid override is ignored
    assert(power_policy_decide(&in).percent == 60);

    // --- AR steady level: CONFIG_CARD_AR_BACKLIGHT_PERCENT default 100 -> 85 ---
    // 85 is a real PWM duty, not DC, and it is the number hello/battery report.
    in.ar = true; in.usb = false; in.override_percent = -1; in.idle_ms = 0;
    in.ar_percent = 85;
    d = power_policy_decide(&in);
    assert(!d.dc && d.percent == 85);
    in.usb = true;                                 // USB does not push 85 back to DC 100
    d = power_policy_decide(&in);
    assert(!d.dc && d.percent == 85);
    in.usb = false;
    in.override_percent = 20; in.idle_ms = POWER_OFF_AFTER_MS;   // neither touches it
    d = power_policy_decide(&in);
    assert(!d.dc && d.percent == 85);
    in.override_percent = -1; in.idle_ms = 0;
    in.ar = false; in.ar_percent = -1;

    // --- button blink (CONFIG_CARD_BUTTON_BLINK, default y): toward the far end ---
    // Below full brightness the press flashes UP to 100 and holds it for 120 ms: a
    // screen that dims on a key press reads as a glitch, one that brightens reads
    // as a response.
    assert(power_policy_blink_level(85) == 100);   // the AR default: 85 -> 100 -> 85
    assert(power_policy_blink_level(99) == 100);   // one below the top still goes up
    assert(power_policy_blink_level(60) == 100);   // battery active level
    assert(power_policy_blink_level(40) == 100);
    assert(power_policy_blink_level(30) == 100);
    assert(power_policy_blink_level(10) == 100);
    assert(power_policy_blink_level(1) == 100);    // even a nearly-dark screen flashes
    // Only a level already at the top has nowhere to go but down: 55 %, as before.
    assert(power_policy_blink_level(100) == 55);   // AR at 100 (DC) dips to 55 % PWM
    assert(power_policy_blink_level(255) == 55);   // clamped to 100 first
    // backlight off (or nonsense input) -> 0 = the blink is a no-op. This is now the
    // only input whose result equals the input, i.e. the caller's "nothing to do".
    assert(power_policy_blink_level(0) == 0);
    assert(power_policy_blink_level(-1) == 0);
    // Sweep: at every live level the result is one of the two ends, stays inside the
    // 0..100 range the LEDC duty write takes, and is never equal to the current level
    // (so the caller's "nothing to do" test can only fire on a backlight that is off).
    for (int cur = 1; cur <= 255; cur++) {
        int lvl = power_policy_blink_level(cur);
        assert(lvl == POWER_BLINK_PEAK || lvl == POWER_BLINK_PERCENT);
        assert(lvl >= 0 && lvl <= 100);
        assert(lvl != cur);
    }

    puts("power_policy tests: PASS");
    return 0;
}
