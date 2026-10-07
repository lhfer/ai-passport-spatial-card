# Vendored BSP — provenance

- Upstream: https://github.com/FoloToy/ai-passport `components/bsp`
- Commit: `31759c4d63dd0d0d6580d6f74639ed5315bcd2c3` (2026-09-18 10:34 +0800)
- Copied verbatim (headers, sources, `CMakeLists.txt`, `idf_component.yml`).
- Dependency pins come from `idf_component.yml`: `idf >=5.5.3,<5.6.0`, `lvgl/lvgl ^9.5.0`,
  `espressif/esp_lvgl_port 2.9.0`, `espressif/button 4.2.0`, `espressif/esp_codec_dev 1.6.2`.

## Local changes (keep this list complete when re-syncing)

1. `include/bsp_display.h` / `src/bsp_display.c`: added
   `bool bsp_display_backlight_dc(bool on)`.
   - `on=true`: parks the LEDC duty at 100 %, then `ledc_stop(..., idle_level=1)` so
     GPIO21 is held high as a steady DC level (no 5 kHz PWM ripple in AR camera
     footage).
   - `on=false`: returns to the PWM path at 100 % via `bsp_display_backlight(100)`
     (`ledc_update_duty()` re-enables the signal output).
   - `bsp_display_backlight(percent)` now also clears the DC flag, so any PWM
     request leaves DC mode. `bsp_display_prepare_deep_sleep()` is unchanged
     (it calls `bsp_display_backlight(0)` then `ledc_stop(..., 0)`).
   - Marked with `[Spatial Card local change]` comments in both files.

2. `src/bsp_audio.c`: added `audio_i2s_is_running()` / `audio_i2s_disable()` and routed
   every defensive `i2s_channel_disable()` through them (`audio_disable_i2s_channels()`,
   the RX-failure rollback in `audio_prepare_i2s_reopen()`, and both pre-`i2s_del_channel`
   disables in `audio_cleanup()`).
   - `i2s_channel_disable()` requires the channel to be RUNNING and logs
     `E i2s_common: i2s_channel_disable(...): the channel has not been enabled yet`
     before returning `ESP_ERR_INVALID_STATE`. Upstream mapped that error to OK, but the
     driver had already printed it: four E lines per cue (TX+RX at wake, because sleep
     left both channels stopped; TX+RX at sleep, because `esp_codec_dev`'s close had
     already stopped them).
   - `i2s_channel_get_info()` reports `is_enabled == (state == RUNNING)`, i.e. exactly
     the predicate the driver checks, so the wrapper asks first and skips the call.
     Behaviour is unchanged (the channel still ends up stopped); only the noise is gone.
   - Marked with `[Spatial Card local change]` comments.

No other file differs from upstream.
