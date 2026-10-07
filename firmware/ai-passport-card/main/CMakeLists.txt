set(srcs
    "main.c"
    "app_state.c"
    "ui/ui_screens.c"
    "ui/ui_flip.c"
    "ui/ui_glow.c"
    "link/serial_link.c"
    "link/ble_nus.c"
    "link/proto.c"
    "link/line_buf.c"
    "audio/cues.c"
    "store/stats_store.c"
    "store/stats_rules.c"
    "power/power_policy.c"
    # Generated assets (see tools/gen_fonts.sh and the Hub's `pnpm screens`)
    "../assets/images/theme_base.c"
    "../assets/images/theme_neon_city.c"
    "../assets/images/theme_data_nebula.c"
    "../assets/fonts/font_digits_36.c"
    "../assets/fonts/font_digits_20.c")

idf_component_register(
    SRCS ${srcs}
    INCLUDE_DIRS "."
    REQUIRES bsp bt json nvs_flash esp_timer esp_hw_support esp_driver_usb_serial_jtag
    EMBED_FILES "../assets/cues/celebrate.pcm"
                "../assets/cues/tick.pcm"
                "../assets/cues/connect.pcm")
