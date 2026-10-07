// main/power/power_policy.c — see power_policy.h.
#include "power/power_policy.h"

power_decision_t power_policy_decide(const power_inputs_t *in)
{
    power_decision_t d = { .dc = false, .percent = POWER_LEVEL_ACTIVE };
    // AR first: the level the headset needs wins over USB presence. Only 100 % is
    // DC; anything lower is a real PWM duty (5 kHz, above the camera frame rate).
    if (in->ar) {
        int level = (in->ar_percent >= 0 && in->ar_percent <= 100) ? in->ar_percent
                                                                  : POWER_LEVEL_AR;
        d.percent = (uint8_t)level;
        d.dc = (level == 100);
        return d;
    }
    if (in->usb) {
        d.dc = true;
        d.percent = 100;
        return d;
    }
    if (in->override_percent >= 0 && in->override_percent <= 100) {
        d.percent = (uint8_t)in->override_percent;
        return d;
    }
    if (in->idle_ms >= POWER_OFF_AFTER_MS)      d.percent = 0;
    else if (in->idle_ms >= POWER_DIM_AFTER_MS) d.percent = POWER_LEVEL_DIM;
    else                                        d.percent = POWER_LEVEL_ACTIVE;
    return d;
}

int power_policy_blink_level(int current_percent)
{
    if (current_percent <= 0) return 0;                 // backlight off: nothing to blink
    int cur = current_percent > 100 ? 100 : current_percent;
    // Toward the far end. Anything below full brightness flashes UP, because a
    // screen that dims on a key press reads as a glitch while one that brightens
    // reads as a response; only a level already at the top can go the other way.
    if (cur < POWER_BLINK_PEAK) return POWER_BLINK_PEAK;
    return (cur * POWER_BLINK_PERCENT) / 100;           // 100 -> 55, unchanged
}

#ifdef ESP_PLATFORM
#include "bsp_display.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "sdkconfig.h"

static const char *TAG = "power";
static uint32_t s_last_activity_ms;
static int s_override = -1;
static int s_ar_percent = CONFIG_CARD_AR_BACKLIGHT_PERCENT;
static power_decision_t s_applied = { .dc = false, .percent = 255 };   // 255 = nothing applied yet

void power_policy_init(uint32_t now_ms)
{
    s_last_activity_ms = now_ms;
    s_override = -1;
    s_ar_percent = CONFIG_CARD_AR_BACKLIGHT_PERCENT;
}

// Buttons/celebrate only restore the battery brightness. The AR level is sticky:
// pressing a button during an AR session must not flip the backlight back to 100 %.
void power_policy_note_activity(uint32_t now_ms)
{
    s_last_activity_ms = now_ms;
    s_override = -1;
}

void power_policy_set_override(int percent)
{
    s_override = (percent >= 0 && percent <= 100) ? percent : -1;
}

void power_policy_set_ar_percent(int percent)
{
    s_ar_percent = (percent >= 0 && percent <= 100) ? percent : CONFIG_CARD_AR_BACKLIGHT_PERCENT;
}

void power_policy_reset_ar_percent(void)
{
    s_ar_percent = CONFIG_CARD_AR_BACKLIGHT_PERCENT;
}

power_decision_t power_policy_current(void) { return s_applied; }

// The one place that talks to the backlight hardware. `dc` is not just "100 %":
// it stops the LEDC with idle level 1, which is what keeps the 5 kHz PWM out of the
// headset's camera frames, so the blink restore must go through here too.
static void apply_decision(const power_decision_t *d)
{
    if (d->dc) {
        if (!bsp_display_backlight_dc(true)) bsp_display_backlight(100);
    } else {
        bsp_display_backlight(d->percent);   // also leaves DC mode
    }
}

#ifdef CONFIG_CARD_BUTTON_BLINK
// Button blink: jump to the far end now, on the app task (0 ms after the debounced
// key event), then one periodic esp_timer brings the level back over two
// POWER_BLINK_STEP_MS steps. Up-blink (the 85 % default -> 100): hold the peak for
// both steps and drop back in one go at 120 ms. Down-blink (a session already at
// 100 -> 55): halfway back at 60 ms, exactly the applied decision at 120 ms, as
// before. Everything after the first write runs in the esp_timer task: no LVGL, no
// blocking, and s_applied is only ever *read* there, so power_policy_apply()'s
// idempotent compare and the reported `backlight` stay on the nominal level.
static esp_timer_handle_t s_blink_timer;
static int s_blink_level;
static int s_blink_phase;
static volatile bool s_blink_armed;

static void blink_cb(void *arg)
{
    (void)arg;
    // The esp_timer task outranks the app task, so a callback always runs to
    // completion once dispatched. This flag is what makes the hand-off safe: when
    // power_policy_apply() aborted the blink the app task is about to write the new
    // level itself, and a half-finished step must not land on top of it.
    if (!s_blink_armed) return;
    const power_decision_t d = s_applied;   // whatever the policy wants right now
    const int target = d.dc ? 100 : (int)d.percent;
    if (s_blink_phase == 0) {
        s_blink_phase = 1;
        // Up-blink: the peak is above the steady level, so hold it -- walking back
        // in two steps would read as the screen sagging rather than as one flash.
        if (s_blink_level > target) return;
        int mid = s_blink_level + (target - s_blink_level) / 2;
        bsp_display_backlight((uint8_t)mid);   // still PWM; DC (if any) returns next step
        return;
    }
    apply_decision(&d);
    s_blink_armed = false;
    if (s_blink_timer) (void)esp_timer_stop(s_blink_timer);
}
#endif

// Abandon a running blink; the caller is about to drive the backlight itself.
static void blink_abort(void)
{
#ifdef CONFIG_CARD_BUTTON_BLINK
    s_blink_armed = false;   // before the stop: a dispatched callback bails out
    if (s_blink_timer) (void)esp_timer_stop(s_blink_timer);
    s_blink_phase = 0;
#endif
}

void power_policy_blink(uint32_t now_ms)
{
    (void)now_ms;
#ifdef CONFIG_CARD_BUTTON_BLINK
    // 255 = nothing applied yet, 0 = backlight off: both are no-ops.
    if (s_applied.percent == 0 || s_applied.percent > 100) return;
    int current = s_applied.dc ? 100 : (int)s_applied.percent;
    int level = power_policy_blink_level(current);
    // Either direction is fine; only "nowhere to go" is a no-op.
    if (level <= 0 || level == current) return;
    if (!s_blink_timer) {
        const esp_timer_create_args_t args = { .callback = blink_cb, .name = "card_bl_blink" };
        if (esp_timer_create(&args, &s_blink_timer) != ESP_OK) return;
    }
    s_blink_armed = false;
    (void)esp_timer_stop(s_blink_timer);   // a second press restarts the blink
    s_blink_level = level;
    s_blink_phase = 0;
    bsp_display_backlight((uint8_t)level);
    esp_err_t e = esp_timer_start_periodic(s_blink_timer, (uint64_t)POWER_BLINK_STEP_MS * 1000ULL);
    if (e != ESP_OK) {
        ESP_LOGW(TAG, "blink timer not armed: %s", esp_err_to_name(e));
        apply_decision(&s_applied);   // no restore scheduled: undo the blink right away
        return;
    }
    s_blink_armed = true;
#endif
}

void power_policy_apply(bool ar, bool usb, uint32_t now_ms)
{
    const power_inputs_t in = {
        .ar = ar, .usb = usb,
        .idle_ms = now_ms - s_last_activity_ms,
        .override_percent = s_override,
        .ar_percent = s_ar_percent,
    };
    power_decision_t d = power_policy_decide(&in);
    // Unchanged decision: return without touching the hardware, so the 1 s tick can
    // never cancel a blink that is halfway through its 120 ms.
    if (d.dc == s_applied.dc && d.percent == s_applied.percent) return;
    blink_abort();   // a real level change wins over a blink in flight
    apply_decision(&d);
    ESP_LOGI(TAG, "backlight %s %u%% (ar=%d usb=%d idle=%lus)", d.dc ? "DC" : "PWM",
             d.percent, ar, usb, (unsigned long)(in.idle_ms / 1000u));
    s_applied = d;
}
#endif
