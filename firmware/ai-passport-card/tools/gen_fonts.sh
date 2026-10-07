#!/usr/bin/env bash
# Regenerate the strip LVGL fonts (LVGL 9.5 format, 4 bpp, uncompressed).
# Glyphs: 0-9 . + - k space ♥ from Arial Bold, 万 ▲ ▼ from Arial Unicode (both ship
# with macOS). Space (0x20) and ♥ (0x2665) are what the `strip` override needs on top
# of the follower count (docs/protocol.md "底条覆盖"); keep the set in sync with
# proto_strip_text_valid() and the Hub's STRIP_GLYPHS.
# Noto Sans SC Bold is not installed on the build Mac; drop in any bold sans here.
set -euo pipefail
cd "$(dirname "$0")/.."
DIGITS_FONT="${DIGITS_FONT:-/System/Library/Fonts/Supplemental/Arial Bold.ttf}"
CJK_FONT="${CJK_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}"
for size in 36 20; do
    npx --yes lv_font_conv@1.5.3 \
        --font "$DIGITS_FONT" --range 0x30-0x39,0x2E,0x2B,0x2D,0x6B,0x20,0x2665 \
        --font "$CJK_FONT" --range 0x4E07,0x25B2,0x25BC \
        --size "$size" --bpp 4 --format lvgl --no-compress \
        --lv-include lvgl.h --lv-font-name "font_digits_${size}" \
        --output "assets/fonts/font_digits_${size}.c"
    glyphs=$(grep -c '^    /\* U+' "assets/fonts/font_digits_${size}.c")
    if [[ "$glyphs" != "19" ]]; then
        echo "font_digits_${size}: expected 19 glyphs, got ${glyphs}" >&2
        exit 1
    fi
    echo "font_digits_${size}.c: ${glyphs} glyphs"
done
