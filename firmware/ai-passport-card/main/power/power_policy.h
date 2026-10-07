// main/power/power_policy.h — backlight policy.
//   AR mode                     -> the AR level, whatever USB does:
//                                  85 (CONFIG_CARD_AR_BACKLIGHT_PERCENT default) = PWM at that duty
//                                  (5 kHz/10-bit, invisible to the headset cameras) so the card does
//                                  not over-expose under room light; only an AR level of exactly
//                                  100 is steady DC
//   USB present (not AR)        -> steady DC 100 %
//   on battery, idle < 10 min   -> 60 % PWM
//   on battery, idle < 2 h      -> 30 % PWM
//   on battery, idle >= 2 h     -> off
//   Hub `backlight{percent}`    -> on battery: overrides the battery levels until the next activity
//                                  in AR: sets the AR level for the running AR session (sticky
//                                  across button presses; `set_mode` re-applies the Kconfig default)
//   any button / celebrate      -> activity: restores the bright level (never clears the AR level)
// No deep sleep on battery (v1). The pure decision function is host-tested; the
// apply function talks to the BSP and is compiled only on the target.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#define POWER_DIM_AFTER_MS   (10u * 60u * 1000u)
#define POWER_OFF_AFTER_MS   (2u * 60u * 60u * 1000u)
#define POWER_LEVEL_ACTIVE   60
#define POWER_LEVEL_DIM      30
#define POWER_LEVEL_AR       100   // fallback when ar_percent is unset/out of range (the target
                                   // always passes CONFIG_CARD_AR_BACKLIGHT_PERCENT, now 85)

// Button blink (CONFIG_CARD_BUTTON_BLINK, default y): gives a button press an
// instant physical response on an AR-mode screen that must not repaint. Backlight
// only -- no LVGL, no handshake, no change to the reported level. The blink always
// runs *toward the far end* of the range: from the 85 % AR default it flashes UP to
// 100 and holds, and only a session already at 100 has nowhere to go but down. A
// screen that dims on a key press reads as a glitch, one that flashes brighter
// reads as a response.
#define POWER_BLINK_PEAK     100   // bright end: where any sub-100 level blinks to
#define POWER_BLINK_PERCENT  55    // dark end: 55 % of the level in use (only from 100)
#define POWER_BLINK_STEP_MS  60    // two 60 ms steps -- the blink is 120 ms either way

typedef struct {
    bool ar;                // card mode is AR
    bool usb;               // USB host present
    uint32_t idle_ms;       // time since the last activity
    int override_percent;   // -1 = none; Hub backlight command on battery
    int ar_percent;         // 0..100 AR level; -1 (or out of range) = POWER_LEVEL_AR
} power_inputs_t;

typedef struct {
    bool dc;                // true: steady DC 100 %; false: PWM at `percent`
    uint8_t percent;
} power_decision_t;

power_decision_t power_policy_decide(const power_inputs_t *in);

// Pure decision helper for the button blink: the backlight level a press blinks
// to, always the far end of the range from wherever the backlight is now.
//   0 (or less) in -> 0 out: the backlight is off, the blink must be a no-op.
//   1..99          -> POWER_BLINK_PEAK (100): flash brighter, then back down.
//   100 (or more)  -> POWER_BLINK_PERCENT % of 100 = 55: already at the top, dip.
// A result equal to the input means "no visible blink, do nothing" (only 0 can do
// that now); the caller compares before it writes the backlight.
int power_policy_blink_level(int current_percent);

#ifdef ESP_PLATFORM
// Target-only glue (main task context). Idempotent: applies BSP calls only on change.
void power_policy_init(uint32_t now_ms);
void power_policy_note_activity(uint32_t now_ms);   // clears a Hub override; keeps the AR level
void power_policy_set_override(int percent);        // -1 clears
void power_policy_set_ar_percent(int percent);      // -1 (or out of range) -> Kconfig default
void power_policy_reset_ar_percent(void);           // back to CONFIG_CARD_AR_BACKLIGHT_PERCENT
void power_policy_apply(bool ar, bool usb, uint32_t now_ms);
power_decision_t power_policy_current(void);
// One blink of the backlight (see power_policy_blink_level). Compiled to a no-op
// unless CONFIG_CARD_BUTTON_BLINK is set; the caller decides *when* (app_state.c:
// click/long events in AR mode only). The first hardware write happens inline, so
// the response is immediate; the restore runs on an esp_timer, never on the app
// task, and never rewrites the applied decision, so `hello` / `battery` keep
// reporting the nominal level (85 in a default AR session).
void power_policy_blink(uint32_t now_ms);
#endif
